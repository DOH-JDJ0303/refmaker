/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary log to screen
log.info logo + paramsSummaryLog(workflow) + citation

WorkflowRefmaker.initialise(params, log)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { INPUT_QC      } from '../modules/local/input-qc'
include { MASH          } from '../modules/local/mash'
include { CLUSTER       } from '../modules/local/cluster'
include { CLUSTER_LARGE } from '../modules/local/cluster'
include { SEQTK_SUBSEQ  } from '../modules/local/seqtk_subseq'
include { MAFFT         } from '../modules/local/mafft'
include { CONSENSUS     } from '../modules/local/consensus'
include { FASTANI_AVA   } from '../modules/local/fastani'
include { FASTANI_SEEDS } from '../modules/local/fastani'
include { SUMMARY       } from '../modules/local/summary'


//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow EPITOME {

    ch_versions = Channel.empty()

    Channel.fromPath(params.input)
        .splitCsv(header:true)
        .map{ tuple(it.taxa, it.segment, file(it.assembly, checkIfExists: true), it.length) }
        .set{ manifest } 
    
    // MODULE: Filter low quality sequences
    INPUT_QC(
        manifest
    )

    //
    // MODULE: Run Mash
    //
    MASH (
        INPUT_QC.out.assemblies
    )
    ch_versions = ch_versions.mix(MASH.out.versions.first())

    // MODULE: CLUSTER
    MASH.out.dist.filter{ taxa, segment, dist, count -> count.toInteger() <= 2000 }.set{ small_datasets }
    MASH.out.dist.filter{ taxa, segment, dist, count -> count.toInteger() > 2000 }.set{ large_datasets }
    CLUSTER (
        small_datasets
    )
    CLUSTER_LARGE (
        large_datasets
    )

    CLUSTER
        .out
        .results
        .splitCsv(header: true)
        .concat( CLUSTER_LARGE.out.results.splitCsv(header: true) )
        .map{ tuple(it.taxa, it.segment, it.cluster, it.seq) }
        .groupTuple(by: [0,1,2])
        .combine(INPUT_QC.out.assemblies, by: [0,1])
        .map{ taxa, segment, cluster, contigs, seqs, count -> [ taxa, segment, cluster, contigs, seqs, contigs.size() ] }
        .set{ clusters }

    // MODULE: SEQTK_SUBSEQ
    SEQTK_SUBSEQ(
        clusters
    )

    // MODULE: MAFFT
    MAFFT(
        SEQTK_SUBSEQ
            .out
            .sequences
            .filter{ taxa, segment, cluster, seqs, count -> count > 1 }
            .map{ taxa, segment, cluster, seqs, count -> [ taxa, segment, cluster, seqs ] }
    )
    // recombine with singletons
    SEQTK_SUBSEQ
        .out
        .sequences
        .filter{ taxa, segment, cluster, seqs, count -> count == 1 }
        .map{ taxa, segment, cluster, seqs, count -> [ taxa, segment, cluster, seqs ] }
        .concat(MAFFT.out.fa)
        .set{ alignments }

    // MODULE: Create consensus sequences
    CONSENSUS(
        alignments
    )

    // MODULE: Run blastn
    FASTANI_AVA (
        CONSENSUS.out.fa.groupTuple(by: [0,1]).map{ taxa, segment, cluster, assembly, length -> [ taxa, segment, assembly, length.min() ] }
    )

    if(params.seeds){
        Channel
            .fromPath(params.seeds)
            .splitCsv(header:true)
            .map{ tuple(it.ref, file(it.assembly)) }
            .set{ seeds }
        // MODULE: Run blastn
        FASTANI_SEEDS (
            CONSENSUS.out.fa.map{ taxa, segment, cluster, assembly, length -> assembly }.collect(),
            seeds.map{ ref, assembly -> assembly }.collect()
        )
    }


    // MODULE: Create summary
    SUMMARY(
        CLUSTER.out.results.concat(CLUSTER_LARGE.out.results).splitText().collectFile(name: "all-clusters.csv"),
        CONSENSUS.out.len.splitText().collectFile(name: "all-lengths.csv"),
        FASTANI_AVA.out.ani.splitText().collectFile(name: "all-ani.tsv"),
        params.seeds ? FASTANI_SEEDS.out.ani : [],
        params.seeds ? file(params.seeds) : []
    )
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    /*
    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowRefmaker.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowRefmaker.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()

    */
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
