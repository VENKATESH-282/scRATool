# =============================================================================
#  scRATool — Production Dockerfile
#  All-in-one: R 4.4 + Bioconductor + Python 3 + Flask + Nextflow
#
#  Build:  docker build -t scratool .
#  Run:    docker run -p 5000:5000 -v ./my_results:/app/nextflow/results scratool
# =============================================================================

FROM bioconductor/bioconductor_docker:RELEASE_3_19

LABEL maintainer="VENKATESH-282"
LABEL description="scRATool: End-to-end scRNA-seq analysis pipeline with web GUI"
LABEL version="3.0.0"

# ── 1. System Dependencies ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    rsync \
    curl \
    wget \
    libhdf5-dev \
    libgeos-dev \
    libglpk-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libgdal-dev \
    cmake \
    python3-pip \
    python3-venv \
    default-jdk \
    && rm -rf /var/lib/apt/lists/*

# ── 2. R / Bioconductor Packages ─────────────────────────────────────────────
#    Install in dependency order to maximize Docker layer caching.
#    Each RUN is a separate layer — if a package fails, earlier layers are cached.

# Core Seurat ecosystem
RUN R -e "BiocManager::install(c( \
    'Seurat', 'SeuratObject', 'sctransform', \
    'hdf5r', 'Matrix', 'future', 'future.apply' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# QC & Preprocessing
RUN R -e "BiocManager::install(c( \
    'scDblFinder', 'SoupX', 'DropletUtils', \
    'scater', 'scran', 'SingleCellExperiment' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# Integration & Clustering
RUN R -e "BiocManager::install(c( \
    'harmony', 'batchelor', 'cluster', \
    'clustree', 'MAST' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# Annotation
RUN R -e "BiocManager::install(c( \
    'SingleR', 'celldex', 'AUCell', \
    'clusterProfiler', 'org.Hs.eg.db', 'org.Mm.eg.db', \
    'msigdbr', 'enrichplot', 'DOSE', 'fgsea' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# Differential Expression
RUN R -e "BiocManager::install(c( \
    'DESeq2', 'limma', 'edgeR', 'EnhancedVolcano' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# Trajectory
RUN R -e "BiocManager::install(c( \
    'slingshot', 'tradeSeq', 'monocle3' \
), update=FALSE, ask=FALSE, Ncpus=4)" || true

# Visualization & Utilities
RUN R -e "BiocManager::install(c( \
    'ComplexHeatmap', 'circlize', 'ggrepel', 'patchwork', \
    'ggalluvial', 'viridis', 'RColorBrewer', \
    'cowplot', 'gridExtra', 'pheatmap', \
    'igraph', 'ggraph', 'NMF', 'tidyverse' \
), update=FALSE, ask=FALSE, Ncpus=4)"

# CellChat (from GitHub)
RUN R -e "if (!requireNamespace('remotes', quietly=TRUE)) install.packages('remotes', repos='https://cloud.r-project.org'); \
    remotes::install_github('jinworks/CellChat', upgrade='never')" || true

# NicheNet (from GitHub)
RUN R -e "remotes::install_github('saeyslab/nichenetr', upgrade='never')" || true

# CopyKAT (from GitHub)
RUN R -e "remotes::install_github('navinlabcode/copykat', upgrade='never')" || true

# HGNChelper for scType annotation
RUN R -e "install.packages('HGNChelper', repos='https://cloud.r-project.org')"

# ── 3. Python / Flask Web GUI ────────────────────────────────────────────────
WORKDIR /app

COPY webapp/requirements.txt ./webapp/requirements.txt
RUN pip3 install --no-cache-dir -r webapp/requirements.txt

# ── 4. Nextflow ──────────────────────────────────────────────────────────────
RUN curl -s https://get.nextflow.io | bash && \
    mv nextflow /usr/local/bin/ && \
    chmod +x /usr/local/bin/nextflow && \
    nextflow -version

# ── 5. Copy Application Code ────────────────────────────────────────────────
COPY webapp/          ./webapp/
COPY nextflow/        ./nextflow/
COPY config.R         ./config.R
COPY install_dependencies.R ./install_dependencies.R
COPY part*.R          ./
COPY run_pipeline.sh  ./run_pipeline.sh

# Create required directories
RUN mkdir -p ./webapp/sessions ./webapp/uploads ./nextflow/results

# ── 6. Expose & Launch ──────────────────────────────────────────────────────
EXPOSE 5000

ENV FLASK_ENV=production
WORKDIR /app/webapp

CMD ["python3", "app.py", "5000"]
