#' Plot Cell Counts
#'
#' @name plotCellCounts
#' @family Quality Control Functions
#' @author Michael Steinbaugh, Rory Kirchner
#'
#' @inheritParams general
#'
#' @return `ggplot`.
#'
#' @examples
#' plotCellCounts(indrops_small)
NULL



#' @rdname plotCellCounts
#' @export
setMethod(
    "plotCellCounts",
    signature("SingleCellExperiment"),
    function(
        object,
        interestingGroups,
        fill = getOption("bcbio.discrete.fill", NULL),
        title = "cell counts"
    ) {
        validObject(object)
        interestingGroups <- matchInterestingGroups(
            object = object,
            interestingGroups = interestingGroups
        )
        assertIsFillScaleDiscreteOrNULL(fill)
        assertIsAStringOrNULL(title)

        metrics <- metrics(object, interestingGroups = interestingGroups)

        sampleData <- sampleData(
            object = object,
            interestingGroups = interestingGroups
        )
        if (is.null(sampleData)) {
            sampleData <- unknownSampleData
        } else {
            sampleData[["sampleID"]] <- factor(
                x = rownames(sampleData),
                levels = levels(metrics[["sampleID"]])
            )
        }
        sampleData <- as.data.frame(sampleData)

        # Remove user-defined `nCells` column, if present
        metrics[["nCells"]] <- NULL
        sampleData[["nCells"]] <- NULL

        data <- metrics %>%
            group_by(!!sym("sampleID")) %>%
            summarize(nCells = n()) %>%
            left_join(sampleData, by = "sampleID")

        p <- ggplot(
            data = data,
            mapping = aes(
                x = !!sym("sampleName"),
                y = !!sym("nCells"),
                fill = !!sym("interestingGroups")
            )
        ) +
            geom_bar(
                color = "black",
                stat = "identity"
            ) +
            labs(
                title = title,
                x = NULL,
                fill = paste(interestingGroups, collapse = ":\n")
            )

        # Color palette
        if (!is.null(fill)) {
            p <- p + fill
        }

        # Labels
        if (nrow(data) <= 16L) {
            p <- p + bcbio_geom_label(
                data = data,
                mapping = aes(label = !!sym("nCells")),
                # Align the label just under the top of the bar
                vjust = 1.25
            )
        }

        # Facets
        facets <- NULL
        if (.isAggregate(data)) {
            facets <- c(facets, "aggregate")
        }
        if (is.character(facets)) {
            p <- p + facet_wrap(facets = syms(facets), scales = "free")
        }

        p
    }
)
