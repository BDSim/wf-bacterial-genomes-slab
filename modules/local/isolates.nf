process mlstSearch {
    label "mlst"
    cpus 1
    input:
        tuple val(meta), path("input_genome.fasta.gz")
    output:
        tuple val(meta), path("${meta.alias}.mlst.json")
    script:
    """
    gunzip -c input_genome.fasta.gz > input_genome.fasta
    mlst input_genome.fasta --label ${meta.alias} --json ${meta.alias}.mlst.json
    """
}

process getPointfinderSpecies {
    label "wfbacterialgenomes"
    cpus 1
    input:
        tuple val(meta), path("${meta.alias}.mlst.json")
    output:
        tuple val(meta), stdout
    shell:
    '''
    pf_species=$(workflow-glue pointfinder_species --mlst_json '!{meta.alias}.mlst.json')
    echo $pf_species
    '''
}

process resfinder {
    label "amr"
    errorStrategy 'ignore'
    input:
        tuple val(meta), path("input_genome.fasta.gz"), val(species)
        val resfinder_threshold
        val resfinder_coverage
    output:
        tuple val(meta), path("${meta.alias}_resfinder_results"), val(species)
    script:
    """
    gunzip -c -f input_genome.fasta.gz > input_genome.fasta

    python -m resfinder \
        -o ${meta.alias}_resfinder_results \
        -l ${resfinder_coverage} \
        -u \
        -t ${resfinder_threshold} \
        --acquired \
        -s "${species}" \
        --point \
        -ifa input_genome.fasta \
        --nanopore \
        --disinfectant || exit 0
    """
}


process processResfinder {
    // Disinfection not processed yet (CW-2106)
    label "wfbacterialgenomes"
    input:
        tuple val(meta), path("${meta.alias}_resfinder_results"), val(species)
    output:
        tuple val(meta), path("${meta.alias}.resfinder_results.txt")
    script:
    if (species == "other")
        """
        workflow-glue process_resfinder \
            --resfinder_file ${meta.alias}_resfinder_results/ResFinder_results_tab.txt \
            --output ${meta.alias}.resfinder_results.txt
        """
    else
        """
        workflow-glue process_resfinder \
            --resfinder_file ${meta.alias}_resfinder_results/ResFinder_results_tab.txt \
            --pointfinder_file ${meta.alias}_resfinder_results/PointFinder_results.txt \
            --output ${meta.alias}.resfinder_results.txt \
            --database_location ${meta.alias}_resfinder_results/pointfinder_blast/tmp/
        """
}

workflow run_isolates {
   take:
      consensus
      resfinder_threshold
      resfinder_coverage
   main:
        mlst_results = mlstSearch(consensus)
        pointfinder_species = getPointfinderSpecies(mlst_results).map{ meta, species -> [meta, species.trim()] }
        // Added with tuple meta to ensure species tied to correct sample
        resfinder_input = consensus.join(pointfinder_species)
        amr_results = resfinder(resfinder_input, resfinder_threshold, resfinder_coverage)
        // Breaks if I pass amr_results as single tuple with species attached
        // ERROR ~ Invalid method invocation `call` with arguments (LOOK INTO)
        // processed = processResfinder(amr_results, pointfinder_species.map{it -> it[1]})
        processed = processResfinder(amr_results)
   emit:
      amr = amr_results
      report_table = processed
      mlst = mlst_results
}
