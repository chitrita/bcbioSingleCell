#' Read 10X Genomics Cell Ranger Data
#'
#' Read [10x Genomics Chromium](https://www.10xgenomics.com/software/) cell
#' counts from `barcodes.tsv`, `genes.tsv`, and `matrix.mtx` files.
#'
#' @details This function is a variant of the main [bcbioSingleCell()]
#'   constructor, but optimized for handling Cell Ranger output.
#'
#' @note Unlike the [bcbioSingleCell()] function, here the `organism`,
#'   `ensemblRelease`, and `genomeBuild` are always detected automatically,
#'   based on the 10X `refdataDir` YAML metadata. Therefore, these parameters
#'   cannot be set by the user.
#'
#' @family Read Functions
#' @author Michael Steinbaugh
#'
#' @inheritParams bcbioSingleCell
#' @inheritParams general
#' @param uploadDir Path to Cell Ranger output directory. This directory path
#'   must contain `filtered_gene_bc_matrices*` as a child directory.
#' @param refdataDir Directory path to Cell Ranger reference annotation data.
#'
#' @return `SingleCellExperiment`.
#' @export
#'
#' @examples
#' uploadDir <- system.file("extdata/cellranger", package = "bcbioSingleCell")
#' x <- readCellRanger(
#'     uploadDir = uploadDir,
#'     refdataDir = file.path(uploadDir, "refdata-cellranger-hg19-1.2.0"),
#'     sampleMetadataFile = file.path(uploadDir, "metadata.csv")
#' )
#' show(x)
readCellRanger <- function(
    uploadDir,
    refdataDir,
    sampleMetadataFile,
    interestingGroups = "sampleName",
    transgeneNames = NULL,
    spikeNames = NULL,
    ...
) {
    assert_is_a_string(uploadDir)
    assert_all_are_dirs(uploadDir)
    uploadDir <- normalizePath(uploadDir, winslash = "/", mustWork = TRUE)
    assert_is_a_string(refdataDir)
    assert_all_are_dirs(refdataDir)
    refdataDir <- normalizePath(refdataDir, winslash = "/", mustWork = TRUE)
    assert_is_character(interestingGroups)
    assert_is_a_string(sampleMetadataFile)
    assertIsCharacterOrNULL(transgeneNames)
    assertIsCharacterOrNULL(spikeNames)
    dots <- list(...)
    pipeline <- "cellranger"
    level <- "genes"
    umiType <- "chromium"

    # Legacy arguments =========================================================
    # annotable
    if ("annotable" %in% names(call)) {
        stop("`annotable` argument is defunct")
    }
    dots <- Filter(Negate(is.null), dots)

    # Directory paths ==========================================================
    sampleDirs <- .sampleDirs(uploadDir, pipeline = pipeline)

    # Sample metadata ==========================================================
    sampleData <- readSampleData(sampleMetadataFile)

    # Interesting groups =======================================================
    # Ensure internal formatting in camelCase
    interestingGroups <- camel(interestingGroups, strict = FALSE)
    assertFormalInterestingGroups(sampleData, interestingGroups)

    # Subset sample directories by metadata ====================================
    if (nrow(sampleData) < length(sampleDirs)) {
        message("Loading a subset of samples, defined by the metadata file")
        allSamples <- FALSE
        sampleDirs <- sampleDirs %>%
            .[names(sampleDirs) %in% rownames(sampleData)]
        message(paste(length(sampleDirs), "samples matched by metadata"))
    } else {
        allSamples <- TRUE
    }

    # Reference data ===========================================================
    # JSON data
    refJSONFile <- file.path(refdataDir, "reference.json")
    assert_all_are_existing_files(refJSONFile)
    refJSON <- read_json(refJSONFile)
    genomeBuild <- refJSON %>%
        .[["genomes"]] %>%
        .[[1L]] %>%
        # CellRanger uses UCSC build names in directories (e.g. hg19)
        convertUCSCBuildToEnsembl()
    assert_is_a_string(genomeBuild)
    organism <- detectOrganism(genomeBuild)
    assert_is_a_string(organism)
    # Get the Ensembl version from the JSON reference file (via GTF)
    ensemblRelease <- refJSON %>%
        .[["input_gtf_files"]] %>%
        .[[1L]] %>%
        str_split("\\.", simplify = TRUE) %>%
        .[1L, 3L] %>%
        as.integer()
    assert_is_an_integer(ensemblRelease)
    assert_all_are_positive(ensemblRelease)
    message(paste(
        paste("Organism:", deparse(organism)),
        paste("Genome build:", deparse(genomeBuild)),
        paste("Ensembl release:", deparse(ensemblRelease)),
        sep = "\n"
    ))

    # Gene annotations =========================================================
    # CellRanger uses Ensembl refdata internally. Here we're fetching the
    # annotations with AnnotationHub rather than pulling from the GTF file
    # in the refdata directory. It will also drop genes that are now dead in the
    # current Ensembl release. Don't warn about old Ensembl release version.
    ah <- suppressWarnings(makeGRangesFromEnsembl(
        organism = organism,
        format = level,
        genomeBuild = genomeBuild,
        release = ensemblRelease,
        metadata = TRUE
    ))
    assert_is_list(ah)
    assert_are_identical(names(ah), c("data", "metadata"))
    rowRanges <- ah[["data"]]
    assert_is_all_of(rowRanges, "GRanges")
    rowRangesMetadata <- ah[["metadata"]]
    assert_is_data.frame(rowRangesMetadata)

    # Require gene-to-symbol mappings
    assert_is_subset(
        x = c("geneID", "geneName"),
        y = names(mcols(rowRanges))
    )

    rowData <- as.data.frame(rowRanges)
    rownames(rowData) <- names(rowRanges)

    # Counts ===================================================================
    message("Reading counts at gene level")
    sparseCountsList <- .sparseCountsList(
        sampleDirs = sampleDirs,
        pipeline = pipeline,
        umiType = umiType
    )
    counts <- do.call(cbind, sparseCountsList)

    # Column data ==============================================================
    # Always prefilter, removing cells with no UMIs or genes
    colData <- metrics(counts, rowData = rowData)

    # Subset the counts to match the prefiltered metrics
    counts <- counts[, rownames(colData), drop = FALSE]

    # Cell to sample mappings ==================================================
    # Check for multiplexed samples. CellRanger outputs these with a trailing
    # number (e.g. `-2$`, which we're sanitizing to `_2$`).
    if (any(grepl(x = colnames(counts), pattern = "_\\d+$"))) {
        if (!"index" %in% colnames(sampleData)) {
            stop(paste(
                "`index` column must be defined using",
                "`sampleMetadataFile` for multiplexed samples"
            ))
        }
        sampleDataMap <- sampleData %>%
            rownames_to_column("sampleID") %>%
            mutate(description = gsub("-\\d$", "", !!sym("description"))) %>%
            mutate_if(is.character, as.factor)
        # Prepare data.frame of barcode mappings
        map <- str_match(
            string = colnames(counts),
            pattern = "^(.+)_([ACGT]+)_(\\d+)$"
        ) %>%
            as.data.frame() %>%
            set_colnames(c(
                "cellID",
                "description",
                "barcode",
                "index"
            )) %>%
            mutate_all(as.factor) %>%
            # Note that we can't use minimal sample metadata here
            left_join(sampleDataMap, by = c("description", "index"))
        cell2sample <- map[["sampleID"]]
        names(cell2sample) <- map[["cellID"]]
    } else {
        cell2sample <- mapCellsToSamples(
            cells = colnames(counts),
            samples = rownames(sampleData)
        )
    }

    # Metadata =================================================================
    metadata <- list(
        "version" = packageVersion,
        "pipeline" = pipeline,
        "level" = level,
        "uploadDir" = uploadDir,
        "sampleDirs" = sampleDirs,
        "sampleMetadataFile" = as.character(sampleMetadataFile),
        "sampleData" = sampleData,
        "interestingGroups" = interestingGroups,
        "cell2sample" = as.factor(cell2sample),
        "organism" = organism,
        "genomeBuild" = as.character(genomeBuild),
        "ensemblRelease" = as.integer(ensemblRelease),
        "rowRangesMetadata" = rowRangesMetadata,
        "umiType" = umiType,
        "allSamples" = allSamples,
        # cellranger pipeline-specific -----------------------------------------
        "refdataDir" = refdataDir,
        "refJSON" = refJSON,
        "call" = match.call()
    )
    # Add user-defined custom metadata, if specified
    if (length(dots)) {
        assert_are_disjoint_sets(names(metadata), names(dots))
        metadata <- c(metadata, dots)
    }

    # Return ===================================================================
    .new.SingleCellExperiment(
        assays = list("counts" = counts),
        rowRanges = rowRanges,
        colData = colData,
        metadata = metadata,
        transgeneNames = transgeneNames,
        spikeNames = spikeNames
    )
}