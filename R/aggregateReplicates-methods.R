#' Aggregate Replicates
#'
#' @name aggregateReplicates
#' @family Data Functions
#' @author Michael Steinbaugh, Rory Kirchner
#'
#' @importFrom basejump aggregateReplicates
#'
#' @inheritParams general
#'
#' @return `SingleCellExperiment`.
#'
#' @examples
#' object <- indrops_small
#' sampleNames(object)
#'
#' # Define groupings factor as`aggregate` column in `colData()`
#' glimpse(object$aggregate)
#'
#' x <- aggregateReplicates(object)
#' show(x)
#' sampleNames(x)
NULL



#' @rdname aggregateReplicates
#' @export
setMethod(
    "aggregateReplicates",
    signature("bcbioSingleCell"),
    function(object) {
        validObject(object)
        sampleData <- as.data.frame(sampleData(object))
        if ("sampleNameAggregate" %in% colnames(sampleData)) {
            warning("Use `aggregate` instead of `sampleNameAggregate`")
            sampleData[["aggregate"]] <- sampleData[["sampleNameAggregate"]]
            sampleData[["sampleNameAggregate"]] <- NULL
        }
        assert_is_subset("aggregate", colnames(sampleData))

        # Consider adding an assert check here to check that interesting
        # groups map to aggregate-level sample columns
        interestingGroupsAggregate <- interestingGroups(object) %>%
            as.character() %>%
            setdiff("sampleName")

        # This step will replace the `sampleName` column with the `aggregate`
        # column metadata.
        remap <- sampleData %>%
            rownames_to_column("sampleID") %>%
            as_tibble() %>%
            select(!!!syms(unique(c(
                "sampleID", "aggregate", interestingGroupsAggregate
            )))) %>%
            mutate(sampleIDAggregate = makeNames(
                !!sym("aggregate"), unique = FALSE
            )) %>%
            rename(sampleNameAggregate = !!sym("aggregate")) %>%
            arrange(!!!syms(c("sampleID", "sampleIDAggregate"))) %>%
            mutate_all(as.factor) %>%
            mutate_all(droplevels)

        # Update sampleData to use the aggregate groupings
        sampleData <- remap %>%
            select(!!!syms(unique(c(
                "sampleIDAggregate",
                "sampleNameAggregate",
                interestingGroupsAggregate
            )))) %>%
            rename(sampleName = !!sym("sampleNameAggregate")) %>%
            unique() %>%
            as.data.frame() %>%
            column_to_rownames("sampleIDAggregate") %>%
            as("DataFrame")

        # Message the new sample IDs
        message(paste(
            "New sample names:",
            toString(unique(remap[["sampleNameAggregate"]]))
        ))

        message("Remapping cellular barcodes to aggregate sample IDs")
        cell2sample <- cell2sample(object)
        remap <- tibble(
            cellID = names(cell2sample),
            sampleID = cell2sample
        ) %>%
            left_join(remap, by = "sampleID")

        groupings <- mapply(
            FUN = gsub,
            x = remap[["cellID"]],
            pattern = paste0("^", remap[["sampleID"]]),
            replacement = remap[["sampleIDAggregate"]]
        ) %>%
            as.factor()

        # Assays ---------------------------------------------------------------
        message("Aggregating counts")
        counts <- aggregateReplicates(counts(object), groupings = groupings)
        # Check that the count number of counts matches
        if (!identical(sum(assay(object)), sum(counts))) {
            stop("Aggregated counts sum isn't identical to original")
        }

        # Column data ----------------------------------------------------------
        # Always prefilter, removing cells with no UMIs or genes
        metrics <- .metrics(
            object = counts,
            rowRanges = rowRanges(object),
            prefilter = TRUE
        )

        # Cell to sample mappings
        cell2sample <- .mapCellsToSamples(
            cells = rownames(metrics),
            samples = rownames(sampleData)
        )

        sampleData[["sampleID"]] <- rownames(sampleData)
        colData <- as(metrics, "DataFrame")
        colData[["cellID"]] <- rownames(colData)
        colData[["sampleID"]] <- cell2sample
        colData <- merge(
            x = colData,
            y = sampleData,
            by = "sampleID",
            all.x = TRUE
        )
        rownames(colData) <- colData[["cellID"]]
        colData[["cellID"]] <- NULL
        sampleData[["sampleID"]] <- NULL

        # Subset the counts to match the prefiltered metrics
        counts <- counts[, rownames(colData), drop = FALSE]
        cell2sample <- cell2sample[colnames(counts)]

        # Metadata -------------------------------------------------------------
        metadata <- list(
            aggregateReplicates = groupings,
            cell2sample = cell2sample,
            interestingGroups = interestingGroups(object),
            sampleData = sampleData
        )

        # Return ---------------------------------------------------------------
        .new.SingleCellExperiment(
            assays = list(counts = counts),
            rowRanges = rowRanges(object),
            colData = colData,
            metadata = metadata,
            spikeNames = spikeNames(object)
        )
    }
)
