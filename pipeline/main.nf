#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

////////////////////////////////////////////////////////////////////////////////
// Pipeline Parameters & Defaults
////////////////////////////////////////////////////////////////////////////////
// Dataset & Reference
params.samplesheet              = "${projectDir}/assets/samples.csv"
params.annotation_map           = "${projectDir}/assets/cluster_annotations.csv"
params.models_dir               = "${projectDir}/models"
params.outdir                   = "${launchDir}/results"
params.reference_condition      = "CTRL"
params.organism                 = "human"
params.custom_gene_allowlist    = ""
params.custom_gene_panel        = ""
params.scoring_gene_sets        = ""
params.trajectory_exclude_pattern = ""
params.tissue                   = "auto"
params.target_celltypes         = "auto"
params.seed                     = 42

// Quality Control Filtering
params.nfeature_min             = 500
params.nfeature_max             = 6000
params.ncount_min               = 800
params.ncount_max               = 50000
params.mt_thresh                = 15
params.min_pct_cells            = 0.1
params.n_hvg                    = 2000

// QC Tool Compare
params.qc_npcs                  = 30
params.qc_resolution            = 0.8
params.qc_seed                  = 12345

// Integration & Clustering
params.npcs                     = 30
params.resolutions              = "0.2,0.4,0.6,0.8,1.0"
params.default_resolution       = "auto"

// Cell Annotation
params.marker_min_pct           = 0.25
params.marker_logfc_thresh      = 0.25
params.top_n_markers            = 5
params.sctype_quantile          = 0.6

// Differential Expression & Pseudobulk
params.de_test                  = "wilcox"
params.de_min_pct               = 0.1
params.de_logfc_thresh          = 0.25
params.de_fdr_thresh            = 0.05
params.pb_min_counts            = 10
params.pb_min_samples           = 2

// Trajectory
params.trajectory_root_celltype = "auto"
params.slingshot_approx_points  = 150

// CellChat
params.cellchat_min_cells       = 10
params.cellchat_prob_type       = "triMean"

// NicheNet
params.nichenet_receiver        = "auto"
params.nichenet_min_expr_pct    = 0.05
params.nichenet_top_ligands     = 20
params.nichenet_cutoff          = 0.25

// CopyKAT
params.copykat_genome           = "hg20"
params.copykat_ks_cut           = 0.1
params.copykat_min_cells        = 200

// hdWGCNA
params.hdwgcna_k_metacell       = 20
params.hdwgcna_min_cells        = 40
params.hdwgcna_target_metacells = 1000
params.hdwgcna_min_module_size  = 30
params.hdwgcna_merge_cut_height = 0.25

// Execution toggles
params.skip_qc_compare          = false
params.skip_monocle3            = false
params.skip_slingshot           = false
params.skip_cellchat            = false
params.skip_nichenet            = false
params.skip_copykat             = false
params.skip_hdwgcna             = false
params.skip_velocity            = false
params.skip_figures             = false


////////////////////////////////////////////////////////////////////////////////
// PROCESS 1: Quality Control & Cell/Gene Filtering
////////////////////////////////////////////////////////////////////////////////
process QC_FILTERING {
    tag "QC_Filtering"
    label 'process_medium'
    publishDir "${params.outdir}/01_qc", mode: 'copy'

    input:
    path samplesheet

    output:
    path "filtered_data",                         emit: filtered_dir
    path "qc_metrics/QC_summary_all_samples.csv", emit: qc_summary
    path "plots",                                 emit: plots
    path "raw_downloads", optional: true,         emit: raw_downloads

    script:
    """
    01_qc_filtering.R \\
        --samplesheet ${samplesheet} \\
        --outdir . \\
        --nfeature_min ${params.nfeature_min} \\
        --nfeature_max ${params.nfeature_max} \\
        --ncount_min ${params.ncount_min} \\
        --ncount_max ${params.ncount_max} \\
        --mt_thresh ${params.mt_thresh} \\
        --min_pct_cells ${params.min_pct_cells} \\
        --n_hvg ${params.n_hvg} \\
        --custom_gene_allowlist "${params.custom_gene_allowlist}" \\
        --organism "${params.organism}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p filtered_data qc_metrics plots
    touch filtered_data/sample1.rds
    echo "sample_id,n_cells,median_genes,median_umi" > qc_metrics/QC_summary_all_samples.csv
    echo "S1,1000,1500,4000" >> qc_metrics/QC_summary_all_samples.csv
    touch plots/qc_violin.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 2: QC Tool Comparison (DecontX & DoubletFinder vs scDblFinder)
////////////////////////////////////////////////////////////////////////////////
process QC_TOOL_COMPARE {
    tag "QC_Tool_Compare"
    label 'process_medium'
    publishDir "${params.outdir}/02_qc_tool_compare", mode: 'copy'

    input:
    path filtered_dir

    output:
    path "QC_tool_comparison_summary.csv", emit: summary
    path "plots",                          emit: plots
    path "filtered_data",                  emit: toolcompare_dir

    script:
    """
    02_qc_tool_compare.R \\
        --input_dir ${filtered_dir} \\
        --outdir . \\
        --npcs ${params.qc_npcs} \\
        --resolution ${params.qc_resolution} \\
        --seed ${params.qc_seed}
    """

    stub:
    """
    mkdir -p plots filtered_data
    echo "sample_id,tool,doublets_detected,pct_doublets" > QC_tool_comparison_summary.csv
    echo "S1,DoubletFinder,50,5.0" >> QC_tool_comparison_summary.csv
    touch plots/tool_compare.png
    touch filtered_data/sample1.rds
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 3: Integration Benchmarking & Clustering
////////////////////////////////////////////////////////////////////////////////
process INTEGRATION_CLUSTERING {
    tag "Integration_Clustering"
    label 'process_high'
    publishDir "${params.outdir}/03_integration", mode: 'copy'

    input:
    path filtered_dir
    path samplesheet

    output:
    path "integrated_data/integrated_clustered_seurat.rds", emit: integrated_rds
    path "metadata",                                        emit: metadata
    path "plots",                                           emit: plots

    script:
    """
    03_integration_clustering.R \\
        --input_dir ${filtered_dir} \\
        --samplesheet ${samplesheet} \\
        --outdir . \\
        --preferred_method auto \\
        --npcs ${params.npcs} \\
        --resolutions "${params.resolutions}" \\
        --default_resolution "${params.default_resolution}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p integrated_data metadata plots
    touch integrated_data/integrated_clustered_seurat.rds
    echo "cluster,n_cells" > metadata/cluster_metrics.csv
    touch plots/umap_integration.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 4: Cell Type Identification & Multi-Method Annotation
////////////////////////////////////////////////////////////////////////////////
process CELL_ANNOTATION {
    tag "Cell_Annotation"
    label 'process_high'
    publishDir "${params.outdir}/04_cell_annotation", mode: 'copy'

    input:
    path integrated_rds

    output:
    path "annotations/integrated_annotated_seurat_draft.rds", emit: draft_rds
    path "annotations/cluster_level_comparison.csv",          emit: cluster_comparison
    path "annotations/all_methods_comparison.csv",            emit: all_methods_comparison
    path "annotations/*.csv",                                 emit: all_csvs
    path "plots",                                             emit: plots

    script:
    """
    04_cell_annotation.R \\
        --integrated_rds ${integrated_rds} \\
        --tissue "${params.tissue}" \\
        --outdir . \\
        --marker_min_pct ${params.marker_min_pct} \\
        --marker_logfc_thresh ${params.marker_logfc_thresh} \\
        --top_n_markers ${params.top_n_markers} \\
        --sctype_quantile ${params.sctype_quantile} \\
        --custom_gene_panel "${params.custom_gene_panel}" \\
        --organism "${params.organism}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p annotations plots
    touch annotations/integrated_annotated_seurat_draft.rds
    echo "cluster,celltype" > annotations/cluster_level_comparison.csv
    echo "cell_id,sctype,singler" > annotations/all_methods_comparison.csv
    echo "cluster,gene,avg_log2FC" > annotations/cluster_markers.csv
    touch plots/annotation_umap.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 5: Differential Expression, Proportions & Functional Scoring
////////////////////////////////////////////////////////////////////////////////
process DIFFERENTIAL_EXPRESSION {
    tag "DE_Functional_Scoring"
    label 'process_high'
    publishDir "${params.outdir}/05_differential_expression", mode: 'copy'

    input:
    path draft_rds
    path annotation_map

    output:
    path "annotations/integrated_annotated_seurat_final_scored.rds", emit: final_scored_rds
    path "annotations/integrated_annotated_seurat_final.rds",        emit: final_rds
    path "results/findmarkers_celllevel_results.csv",                emit: de_celllevel_csv
    path "results/deseq2_pseudobulk_results.csv", optional: true,    emit: deseq2_csv
    path "results/limma_pseudobulk_results.csv",  optional: true,    emit: limma_csv
    path "results/cell_type_proportions_per_sample.csv",             emit: prop_sample_csv
    path "results/pathway_score_tests.csv",       optional: true,    emit: pathway_tests_csv
    path "results",                                                  emit: all_results
    path "plots",                                                    emit: plots

    script:
    """
    05_differential_expression.R \\
        --draft_rds ${draft_rds} \\
        --annotation_map ${annotation_map} \\
        --reference_condition ${params.reference_condition} \\
        --outdir . \\
        --de_test "${params.de_test}" \\
        --de_min_pct ${params.de_min_pct} \\
        --de_logfc_thresh ${params.de_logfc_thresh} \\
        --de_fdr_thresh ${params.de_fdr_thresh} \\
        --pb_min_counts ${params.pb_min_counts} \\
        --pb_min_samples ${params.pb_min_samples} \\
        --custom_gene_panel "${params.custom_gene_panel}" \\
        --scoring_gene_sets "${params.scoring_gene_sets}" \\
        --organism "${params.organism}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p annotations results plots
    touch annotations/integrated_annotated_seurat_final_scored.rds
    touch annotations/integrated_annotated_seurat_final.rds
    echo "gene,cell_type,p_val,avg_log2FC,p_val_adj,contrast" > results/findmarkers_celllevel_results.csv
    echo "gene,cell_type,baseMean,log2FoldChange,padj,contrast" > results/deseq2_pseudobulk_results.csv
    echo "gene,cell_type,logFC,adj.P.Val,contrast" > results/limma_pseudobulk_results.csv
    echo "sample_id,condition,cell_type,cell_count,proportion" > results/cell_type_proportions_per_sample.csv
    echo "pathway,contrast,pval" > results/pathway_score_tests.csv
    touch plots/volcano.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 6: Cross-Platform Object Conversions (SCE & SE)
////////////////////////////////////////////////////////////////////////////////
process OBJECT_CONVERSION {
    tag "Object_Conversion"
    label 'process_medium'
    publishDir "${params.outdir}/06_object_structures", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "examples/sce_full_object.rds",            emit: sce_rds
    path "examples/pseudobulk_SE_by_celltype.rds",  emit: se_rds
    path "plots",                                   emit: plots

    script:
    """
    06_object_conversion.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p examples plots
    touch examples/sce_full_object.rds
    touch examples/pseudobulk_SE_by_celltype.rds
    touch plots/sce_umap.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 7: Monocle 3 Trajectory Analysis
////////////////////////////////////////////////////////////////////////////////
process TRAJECTORY_MONOCLE3 {
    tag "Monocle3_Trajectory"
    label 'process_high'
    publishDir "${params.outdir}/07_trajectory_monocle3", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "results/cds_trajectory_final.rds",           emit: cds_rds
    path "results/seurat_with_pseudotime.rds",         emit: seurat_pt_rds
    path "results/pseudotime_summary_by_celltype.csv", emit: pt_summary
    path "results/*.csv", optional: true,              emit: csvs
    path "plots",                                      emit: plots

    script:
    """
    07_trajectory_monocle3.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --trajectory_root_celltype "${params.trajectory_root_celltype}" \\
        --trajectory_exclude_pattern "${params.trajectory_exclude_pattern}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p results plots
    touch results/cds_trajectory_final.rds
    touch results/seurat_with_pseudotime.rds
    echo "celltype,mean_pseudotime" > results/pseudotime_summary_by_celltype.csv
    echo "status,ok" > results/monocle3_status.txt
    touch plots/monocle3_trajectory.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 8: Slingshot Trajectory Analysis
////////////////////////////////////////////////////////////////////////////////
process TRAJECTORY_SLINGSHOT {
    tag "Slingshot_Trajectory"
    label 'process_high'
    publishDir "${params.outdir}/08_trajectory_slingshot", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "results/sce_*slingshot.rds",                 emit: sce_slingshot
    path "results/seurat_*slingshot.rds",              emit: seurat_slingshot
    path "results/*.csv",                              emit: csvs
    path "plots",                                      emit: plots

    script:
    """
    08_trajectory_slingshot.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --trajectory_root_celltype "${params.trajectory_root_celltype}" \\
        --slingshot_approx_points ${params.slingshot_approx_points} \\
        --trajectory_exclude_pattern "${params.trajectory_exclude_pattern}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p results plots
    touch results/sce_lineage_slingshot.rds
    touch results/sce_myogenic_slingshot.rds
    touch results/seurat_lineage_with_slingshot.rds
    touch results/seurat_myogenic_lineage_with_slingshot.rds
    echo "cell_id,pseudotime" > results/slingshot_pseudotime.csv
    touch plots/slingshot_trajectory.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 9: CellChat Intercellular Communication Analysis
////////////////////////////////////////////////////////////////////////////////
process CELLCHAT_COMMUNICATION {
    tag "CellChat"
    label 'process_high'
    publishDir "${params.outdir}/09_cellchat", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "results/cellchat", emit: cellchat_dir
    path "plots/cellchat",   emit: plots

    script:
    """
    09_cellchat_communication.R \\
        --seurat_rds ${final_scored_rds} \\
        --reference_condition ${params.reference_condition} \\
        --outdir . \\
        --cellchat_min_cells ${params.cellchat_min_cells} \\
        --cellchat_prob_type "${params.cellchat_prob_type}" \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p results/cellchat plots/cellchat
    touch results/cellchat/cellchat_CTRL.rds
    touch plots/cellchat/diff_interaction.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 10: NicheNet Mechanistic Signaling Analysis
////////////////////////////////////////////////////////////////////////////////
process NICHENET_COMMUNICATION {
    tag "NicheNet"
    label 'process_high'
    publishDir "${params.outdir}/10_nichenet", mode: 'copy'

    input:
    path final_scored_rds
    path models_dir

    output:
    path "results/nichenet", emit: tables
    path "plots/nichenet",   emit: plots

    script:
    """
    10_nichenet_communication.R \\
        --seurat_rds ${final_scored_rds} \\
        --models_dir ${models_dir} \\
        --reference_condition ${params.reference_condition} \\
        --outdir . \\
        --nichenet_receiver "${params.nichenet_receiver}" \\
        --nichenet_min_expr_pct ${params.nichenet_min_expr_pct} \\
        --nichenet_top_ligands ${params.nichenet_top_ligands} \\
        --nichenet_cutoff ${params.nichenet_cutoff} \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p results/nichenet plots/nichenet
    echo "test_ligand,pearson" > results/nichenet/ligand_activities.csv
    touch plots/nichenet/ligand_target.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 11: CopyKAT Large-Scale Aneuploidy / CNV Inference
////////////////////////////////////////////////////////////////////////////////
process COPYKAT_CNV {
    tag "CopyKAT_CNV"
    label 'process_high'
    publishDir "${params.outdir}/11_copykat", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "annotations/integrated_annotated_seurat_final_scored_copykat.rds", optional: true, emit: copykat_rds
    path "results/copykat",                                                                   emit: results
    path "plots/copykat",                                                                     emit: plots

    script:
    """
    11_copykat_cnv.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --n_cores ${task.cpus} \\
        --min_cells ${params.copykat_min_cells} \\
        --copykat_genome "${params.copykat_genome}" \\
        --copykat_ks_cut ${params.copykat_ks_cut} \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p annotations results/copykat plots/copykat
    touch annotations/integrated_annotated_seurat_final_scored_copykat.rds
    echo "sample_id,condition,n_cells,status" > results/copykat/copykat_run_status.csv
    touch plots/copykat/cnv_heatmap.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 12: hdWGCNA Gene Co-Expression Networks
////////////////////////////////////////////////////////////////////////////////
process HDWGCNA_NETWORKS {
    tag "hdWGCNA"
    label 'process_high'
    publishDir "${params.outdir}/12_hdwgcna", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "annotations/integrated_annotated_seurat_hdwgcna.rds", optional: true, emit: hdwgcna_rds
    path "results/hdwgcna",                                                     emit: results
    path "plots/hdwgcna",                                                       emit: plots

    script:
    """
    12_hdwgcna_networks.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --target_celltypes "${params.target_celltypes}" \\
        --reference_condition ${params.reference_condition} \\
        --n_threads ${task.cpus} \\
        --hdwgcna_k_metacell ${params.hdwgcna_k_metacell} \\
        --hdwgcna_min_cells ${params.hdwgcna_min_cells} \\
        --hdwgcna_target_metacells ${params.hdwgcna_target_metacells} \\
        --hdwgcna_min_module_size ${params.hdwgcna_min_module_size} \\
        --hdwgcna_merge_cut_height ${params.hdwgcna_merge_cut_height} \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p annotations results/hdwgcna plots/hdwgcna
    touch annotations/integrated_annotated_seurat_hdwgcna.rds
    echo "gene_name,module,color" > results/hdwgcna/modules.csv
    touch plots/hdwgcna/network_dendrogram.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 13: Export for RNA Velocity (scVelo)
////////////////////////////////////////////////////////////////////////////////
process VELOCITY_EXPORT {
    tag "Velocity_Export"
    label 'process_low'
    publishDir "${params.outdir}/13_velocity_inputs", mode: 'copy'

    input:
    path final_scored_rds

    output:
    path "*.csv", emit: csvs

    script:
    """
    13_velocity_export.R \\
        --seurat_rds ${final_scored_rds} \\
        --outdir . \\
        --seed ${params.seed}
    """

    stub:
    """
    echo "cell_key,sample_id,condition,final_annotation,lineage_myogenic" > scvelo_metadata.csv
    echo "cell_key,PC_1,PC_2" > pca_embeddings.csv
    """
}

////////////////////////////////////////////////////////////////////////////////
// PROCESS 14: Publication-Grade Figures Synthesis
////////////////////////////////////////////////////////////////////////////////
process PUBLICATION_FIGURES {
    tag "Publication_Figures"
    label 'process_medium'
    publishDir "${params.outdir}/14_publication_figures", mode: 'copy'

    input:
    path final_scored_rds
    path de_celllevel_csv
    path cellchat_dir

    output:
    path "plots", emit: plots

    script:
    """
    14_publication_figures.R \\
        --seurat_rds ${final_scored_rds} \\
        --de_csv ${de_celllevel_csv} \\
        --cellchat_dir ${cellchat_dir} \\
        --outdir . \\
        --seed ${params.seed}
    """

    stub:
    """
    mkdir -p plots
    touch plots/fig1_qc_distribution.png
    touch plots/fig2_umap_clustering.png
    """
}

////////////////////////////////////////////////////////////////////////////////
// Main Workflow
////////////////////////////////////////////////////////////////////////////////
workflow {
    log.info """
    ================================================================================
     scRATool: scRNA-seq Downstream Analysis Automated Nextflow Pipeline
    ================================================================================
     Samplesheet:         ${params.samplesheet}
     Annotation Map:      ${params.annotation_map}
     Models Directory:    ${params.models_dir}
     Output Directory:    ${params.outdir}
     Conditions:          All dataset samples (CTRL, FSHD1, FSHD2)
     Baseline Reference:  ${params.reference_condition} (used for pairwise contrasts)
     Organism:            ${params.organism}
     Tissue Model:        ${params.tissue}
     Random Seed:         ${params.seed}
    ================================================================================
    """

    ch_samplesheet    = file(params.samplesheet, checkIfExists: true)
    ch_annotation_map = file(params.annotation_map, checkIfExists: true)
    ch_models_dir     = file(params.models_dir)

    // Stage 1: Quality Control & Filtering
    QC_FILTERING(ch_samplesheet)

    // Stage 2: QC Tool Comparison (optional)
    if (!params.skip_qc_compare) {
        QC_TOOL_COMPARE(QC_FILTERING.out.filtered_dir)
    }

    // Stage 3: Integration & Clustering
    INTEGRATION_CLUSTERING(QC_FILTERING.out.filtered_dir, ch_samplesheet)

    // Stage 4: Cell Annotation
    CELL_ANNOTATION(INTEGRATION_CLUSTERING.out.integrated_rds)

    // Stage 5: Differential Expression & Functional Scoring
    DIFFERENTIAL_EXPRESSION(CELL_ANNOTATION.out.draft_rds, ch_annotation_map)

    // Downstream Concurrent Stages
    OBJECT_CONVERSION(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)

    if (!params.skip_monocle3) {
        TRAJECTORY_MONOCLE3(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_slingshot) {
        TRAJECTORY_SLINGSHOT(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_cellchat) {
        CELLCHAT_COMMUNICATION(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_nichenet) {
        NICHENET_COMMUNICATION(DIFFERENTIAL_EXPRESSION.out.final_scored_rds, ch_models_dir)
    }

    if (!params.skip_copykat) {
        COPYKAT_CNV(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_hdwgcna) {
        HDWGCNA_NETWORKS(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_velocity) {
        VELOCITY_EXPORT(DIFFERENTIAL_EXPRESSION.out.final_scored_rds)
    }

    if (!params.skip_figures) {
        // Collect outputs from DE and CellChat for publication figures
        ch_cc_dir = params.skip_cellchat ? file("${params.outdir}/empty_cc") : CELLCHAT_COMMUNICATION.out.cellchat_dir
        PUBLICATION_FIGURES(
            DIFFERENTIAL_EXPRESSION.out.final_scored_rds,
            DIFFERENTIAL_EXPRESSION.out.de_celllevel_csv,
            ch_cc_dir
        )
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Workflow Completion Handler (Provenance & Results Manifest)
    ////////////////////////////////////////////////////////////////////////////////
    def targetOutdir = params.outdir
    def pipelineParams = params
    def wf = workflow

    workflow.onComplete {
        try {
            def pipelineInfoDir = new File("${targetOutdir}/pipeline_info")
            pipelineInfoDir.mkdirs()

            // 1. Provenance tracking
            def provenance = [
                run_name: wf.runName,
                session_id: wf.sessionId,
                start_time: wf.start ? wf.start.format("yyyy-MM-dd'T'HH:mm:ssXXX") : null,
                complete_time: wf.complete ? wf.complete.format("yyyy-MM-dd'T'HH:mm:ssXXX") : null,
                duration: wf.duration ? wf.duration.toString() : null,
                success: wf.success,
                exit_status: wf.exitStatus,
                command_line: wf.commandLine,
                project_dir: wf.projectDir?.toString(),
                launch_dir: wf.launchDir?.toString(),
                work_dir: wf.workDir?.toString(),
                parameters: pipelineParams
            ]

            def provFile = new File(pipelineInfoDir, "provenance.json")
            provFile.text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(provenance))

            // 2. Results Manifest
            def resultsDir = new File("${targetOutdir}")
            def manifestEntries = []

            if (resultsDir.exists()) {
                resultsDir.eachFileRecurse(groovy.io.FileType.FILES) { file ->
                    def relPath = resultsDir.toPath().relativize(file.toPath()).toString()
                    if (!relPath.startsWith("pipeline_info/")) {
                        def ext = file.name.tokenize('.').last().toLowerCase()
                        def cat = "other"
                        if (ext in ["png", "pdf", "svg", "jpg", "jpeg"]) cat = "plots"
                        else if (ext in ["csv", "tsv", "txt"]) cat = "tables"
                        else if (ext in ["rds", "h5ad", "loom", "rdata"]) cat = "objects"
                        else if (ext in ["html", "json"]) cat = "reports"

                        manifestEntries.add([
                            relative_path: relPath,
                            file_name: file.name,
                            category: cat,
                            size_bytes: file.length(),
                            last_modified: file.lastModified()
                        ])
                    }
                }
            }

            def manifest = [
                generated_at: new java.util.Date().format("yyyy-MM-dd'T'HH:mm:ssXXX"),
                total_files: manifestEntries.size(),
                files: manifestEntries
            ]

            def manifestFile = new File(pipelineInfoDir, "results_manifest.json")
            manifestFile.text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(manifest))

            println "\nPipeline execution completed at: ${new java.util.Date()}"
            println "Execution status: ${wf.success ? 'SUCCESS' : 'FAILED'}"
            println "Provenance saved to: ${provFile.absolutePath}"
            println "Manifest saved to:   ${manifestFile.absolutePath}\n"
        } catch (Exception e) {
            println "Notice: Completed with notice in metadata logger: ${e.message}"
        }
    }
}
