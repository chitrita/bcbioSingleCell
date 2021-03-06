#' Cell to Sample Mappings
#'
#' @name cell2sample
#' @family Data Functions
#' @author Michael Steinbaugh
#'
#' @inheritParams general
#'
#' @return Named `factor` containing sample IDs as the levels and cellular
#'   barcode IDs as the names.
#'
#' @examples
#' x <- cell2sample(indrops_small)
#' table(x)
NULL



#' @rdname cell2sample
#' @export
setMethod(
    "cell2sample",
    signature("SingleCellExperiment"),
    function(object) {
        validObject(object)
        stash <- metadata(object)[["cell2sample"]]
        if (
            is.factor(stash) &&
            identical(colnames(object), names(stash))
        ) {
            return(stash)
        }
        cells <- colnames(object)
        samples <- rownames(sampleData(object))
        if (is.null(samples)) {
            samples <- "unknown"
        }
        .mapCellsToSamples(cells = cells, samples = samples)
    }
)
