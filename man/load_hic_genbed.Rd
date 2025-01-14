% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/io.R
\name{load_hic_genbed}
\alias{load_hic_genbed}
\title{Load Hi-C data in BED format}
\usage{
load_hic_genbed(
  file_path,
  type,
  norm,
  genome,
  sample = NULL,
  resol = NULL,
  chrom = NULL,
  score_col = 7L,
  bootstrap = 1L
)
}
\arguments{
\item{resol}{An integer for the resolution. If \code{NULL}, the resolution will be
guessed from the Hi-C data.}

\item{score_col}{Specify which column represents cofrag scores. Default is 7
(the 7th column).}

\item{bootstrap}{If multiple bootstrap records exist, only return results for
specified bootstrap iterations. If NULL, results for all bootstrap
iterations will be retunred.}
}
\description{
Load Hi-C data in BED format
}
