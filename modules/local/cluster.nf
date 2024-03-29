process CLUSTER {
    tag "${prefix}"
    label "process_high"
    container 'docker.io/johnjare/spree:1.0'
    stageInMode 'copy'

    input:
    tuple val(taxa), val(segment), path(dist), val(seq_count)

    output:
    path "*.csv", emit: results
    path "*.jpg", emit: plot

    when:
    task.ext.when == null || task.ext.when

    script:
    prefix = "${taxa}-${segment}"
    """
    gzip -d ${dist}
    # run script
    cluster.R *.txt "${taxa}" "${segment}" ${params.dist_threshold}
    """
}

process CLUSTER_LARGE {
    tag "${prefix}"
    label "process_high_memory"
    container 'docker.io/johnjare/spree:1.0'

    input:
    tuple val(taxa), val(segment), path(dist), val(seq_count)

    output:
    path "*.csv", emit: results
    path "*.jpg", emit: plot

    when:
    task.ext.when == null || task.ext.when

    script:
    prefix = "${taxa}-${segment}"
    """
    gzip -d ${dist}
    # run script
    cluster.R *.txt "${taxa}" "${segment}" ${params.dist_threshold}
    """
}
