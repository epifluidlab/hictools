# MIT License
#
# Copyright (c) 2021 Haizi Zheng
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Author: Haizi Zheng
# Copyright: Copyright 2021, Haizi Zheng
# Email: haizi.zh@gmail.com
# License: MIT
#
# Tools for analyzing and manipulating Hi-C dataset


#' Load Hi-C dataset from a .hic file
#'
#' This function invokes Juicer tools for the dumping
#' @param file_path Path to the .hic file
#' @param chrom A character vector to indicate what chromosomes to load
#' @param resol Resolution in base pair (BP)
#' @param matrix Should be \code{observed} or \code{oe}
#' @param norm See the manual of Juicer tools.
#' @return A Hi-C object
#' @export
load_juicer_hic <- function(file_path,
                            resol,
                            type,
                            norm,
                            genome,
                            sample = NULL,
                            chrom = NULL) {
  all_chroms <- strawr::readHicChroms(file_path)$name
  if (!is.null(chrom)) {
    valid_chrom_flag <- chrom %in% all_chroms
    assert_that(all(valid_chrom_flag),
                msg = paste0("Invalid chromosomes: ",
                             paste(chrom[!valid_chrom_flag], sep = ", ")))
  } else {
    warning(paste0(
      "Loading all chromosomes in the .hic file: ",
      paste(all_chroms, collapse = ", ")
    ))
    chrom <- all_chroms
  }
  
  assert_that(is_wholenumber(resol))
  resol <- as.integer(resol)
  assert_that(is_scalar_integer(resol) &&
                resol %in% strawr::readHicBpResolutions(file_path),
              msg = str_interp("Resolution ${resol} does not exist in ${file_path}"))
  
  straw_read <- function(chrom, type) {
    strawr::straw(
      norm = norm,
      fname = file_path,
      chr1loc = chrom,
      chr2loc = chrom,
      unit = "BP",
      binsize = resol,
      matrix = type
    ) %>%
      data.table::as.data.table()
  }
  
  chrom %>%
    map(function(chrom) {
      tryCatch({
        if (type == "expected") {
          dt_obs <- straw_read(chrom = chrom, type = "observed")
          dt_oe <- straw_read(chrom = chrom, type = "oe")
          dt <- merge(dt_obs, dt_oe, by = c("x", "y"))[
            , .(x, y, counts = counts.x / counts.y)]
        } else
          dt <- straw_read(chrom = chrom, type = type)
        
        dt <-
          dt[, .(
            chrom1 = chrom,
            pos1 = x,
            chrom2 = chrom,
            pos2 = y,
            score = counts
          )]
        dt[order(chrom1, pos1, chrom2, pos2)]
      }, error = function(e) {
        warning(str_interp("File doesn't have data for chromosome: ${chrom}"))
        NULL
      })
    }) %>%
    data.table::rbindlist() %>%
    ht_table(
      resol = resol,
      type = type,
      norm = norm,
      genome = genome,
      sample = sample
    )
}


#' @export
load_juicer_short <-
  function(file_path,
           chrom = NULL,
           type = c("observed", "oe", "expected", "cofrag"),
           norm = c("NONE", "KR", "VC", "VC_SQRT"),
           genome = NULL) {
    assert_that(is_scalar_character(file_path))
    assert_that(is_null(chrom) || is_character(chrom))
    
    type <- match.arg(type)
    norm <- match.arg(norm)
    assert_that(is_null(genome) || is_scalar_character(genome))

    # 0 22 16000000 0 0 22 16000000 1 95
    data <- read_delim(
      file = file_path,
      delim = " ",
      col_names = F,
      col_types = "iciiiciin"
    ) %>%
      rename(
        chrom1 = X2,
        pos1 = X3,
        chrom2 = X6,
        pos2 = X7,
        score = X9
      ) %>%
      select(chrom1, pos1, chrom2, pos2, score) %>%
      data.table::as.data.table()

    resol <- guess_resol(data)
    assert_that(is_valid_resol(resol))

    if (!is_null(chrom)) {
      data <- data[data$chrom1 %in% chrom & data$chrom2 %in% chrom]
    }
    
    chrom <- c(data$chrom1, data$chrom2) %>% unique() %>% as.character()
    data %>% ht_table(resol = resol,
                      type = type,
                      norm = norm,
                      genome = genome)
  }

#' @export
load_juicer_dump <- function(file_path,
                             chrom,
                             type = c("observed", "oe", "expected", "cofrag"),
                             norm = c("NONE", "KR", "VC", "VC_SQRT"),
                             genome = NULL) {
  assert_that(is_scalar_character(file_path))
  assert_that(is_scaler_character(chrom))
  type <- match.arg(type)
  norm <- match.arg(norm)
  assert_that(is_scalar_character(genome))

  # 16000000        16000000        95.0
  data <- read_tsv(
    file = file_path,
    col_names = c("pos1", "pos2", "score"),
    col_types = "iin"
  ) %>%
    mutate(chrom1 = chrom, chrom2 = chrom) %>%
    select(chrom1, pos1, chrom2, pos2, score) %>%
    data.table::as.data.table()

  resol <- guess_resol(data)
  assert_that(is_valid_resol(resol))

  data %>% ht_table(resol = resol, type = type, norm = norm, genome = genome)
}


#' Load Hi-C data in BED format
#' 
#' @param resol An integer for the resolution. If `NULL`, the resolution will be
#'   guessed from the Hi-C data.
#' @param score_col Specify which column represents cofrag scores. Default is 7
#'   (the 7th column).
#' @param bootstrap If multiple bootstrap records exist, only return results for
#'   specified bootstrap iterations. If NULL, results for all bootstrap
#'   iterations will be retunred.
#' @export
load_hic_genbed <- function(file_path,
                            type,
                            norm,
                            genome,
                            sample = NULL,
                            resol = NULL,
                            chrom = NULL,
                            score_col = 7L,
                            bootstrap = 1L) {
  assert_that(is_null(chrom) || is_character(chrom))
  if (!is_null(bootstrap)) {
    assert_that(is_wholenumber(bootstrap))
    bootstrap <- as.integer(bootstrap)
  }
  data <- bedtorch::read_bed(file_path,
                             range = chrom,
                             use_gr = FALSE,
                             genome = genome) %>%
    data.table::as.data.table()
  
  # If the column bootstrap exists, this indicates there are multiple scores for each bin pair
  # due to multiple bootstrap iterations.
  # In this case, we only load scores from the first bootstrap
  if ("bootstrap" %in% colnames(data) && !is_null(bootstrap)) {
    data <- local({
      select_flag <- data$bootstrap %in% bootstrap
      data[select_flag]
    })
  }
  
  # The score column should be the 7th column
  data <- select(data, 1:6, all_of(score_col), dplyr::everything())
  # Fix column names
  col_head <- c("chrom1",
                "pos1",
                "end1",
                "chrom2",
                "pos2",
                "end2",
                "score")
  col_new <-
    make.names(c(col_head, tail(colnames(data), n = -7)), unique = TRUE)
  data.table::setnames(data, new = col_new)
  
  data <-
    data[, `:=`(chrom1 = as.character(chrom1), chrom2 = as.character(chrom2))]
  
  if (is_null(resol))
    resol <- guess_resol(data)
  
  assert_that(is_valid_resol(resol))
  
  data %>% select(-c(end1, end2)) %>%
    ht_table(
      resol = resol,
      type = type,
      norm = norm,
      genome = genome,
      sample = sample
    )
}


#' Load Hi-C data in cool format
#' @export
load_hic_cool <- function(file_path, chrom = NULL,
                          type = c("observed", "oe", "cofrag"),
                          norm = c("NONE", "KR", "VC", "VC_SQRT"),
                          hdf5 = TRUE, cooler = "cooler") {
  stopifnot(hdf5)
  type <- match.arg(type)
  norm <- match.arg(norm)

  # Load the bin table
  if (hdf5) {
    bin_table <- h5read(file_path, "bins") %>%
      as_tibble() %>%
      mutate(chrom = as.character(chrom), bin_id = row_number() - 1)
  } else {
    cmd <-
      str_interp("cooler dump ${file_path} -t bins -H -c chrom,start,end")
    bin_table <-
      read.delim2(file = textConnection(system(cmd, intern = TRUE)), sep = "\t") %>%
      as_tibble() %>%
      mutate(bin_id = row_number() - 1)
  }

  helper_cool <- function(chrom) {
    cmd <-
      str_interp("cooler dump ${file_path} -H")
    if (!is.null(chrom)) {
      cmd <- paste0(cmd, " -r ", chrom)
    }
    observed <-
      read.delim2(file = textConnection(system(cmd, intern = TRUE)),
                  sep = "\t") %>%
      as_tibble() %>%
      modify_at(1:2, as.integer) %>%
      modify_at(3, as.numeric) %>%
      inner_join(x = .,
                 y = bin_table,
                 by = c(bin1_id = "bin_id")) %>%
      inner_join(x = .,
                 y = bin_table,
                 by = c(bin2_id = "bin_id")) %>%
      rename(
        chrom1 = chrom.x,
        chrom2 = chrom.y,
        pos1 = start.x,
        pos2 = start.y,
        score = count
      ) %>%
      select(chrom1, pos1, chrom2, pos2, score)
  }

  helper_h5 <- function() {
    h5read(file_path, "pixels") %>% as_tibble() %>%
      inner_join(x = .,
                 y = bin_table,
                 by = c(bin1_id = "bin_id")) %>%
      inner_join(x = .,
                 y = bin_table,
                 by = c(bin2_id = "bin_id")) %>%
      rename(
        chrom1 = chrom.x,
        chrom2 = chrom.y,
        pos1 = start.x,
        pos2 = start.y,
        score = count
      ) %>%
      select(chrom1, pos1, chrom2, pos2, score)
  }

  # Load the contents
  dt <- if (is.null(chrom)) {
    # Genome-wide dump
    if (hdf5) {
      helper_h5()
    } else {
      helper_cool(chrom = chrom)
    }
  } else {
    if (hdf5) {
      helper_h5() %>% filter(chrom1 %in% chrom & chrom2 %in% chrom)
    } else {
      chrom %>% map_dfr(helper_cool)
    }
  }

  if (!is.null(chrom)) {
    dt %<>% filter(chrom1 %in% chrom & chrom2 %in% chrom)
  } else {
    chrom <- c(dt$chrom1, dt$chrom2) %>% unique()
  }

  dt <- data.table::as.data.table(dt)
  resol <- guess_resol(dt)
  dt %>% ht_table(resol = resol, type = type, norm = norm)
}


# Guess Hi-C format from file name
guess_format <- function(file_path) {
  if (endsWith(file_path, ".hic")) {
    return("juicer_hic")
  } else if (endsWith(file_path, ".bed") || endsWith(file_path, ".bed.gz")) {
    return("genbed")
  } else if (endsWith(file_path, ".short") || endsWith(file_path, ".short.gz")) {
    return("juicer_short")
  } else if(endsWith(file_path, ".cool")) {
    return("cool")
  } else {
    stop(str_interp("Unknown input format: ${file_path}"))
  }
}


# Guess the resolution from data
guess_resol <- function(data) {
  if (all(c("end1", "end2") %in% colnames(data))) {
    resol <- data[, unique(c(end1 - pos1, end2 - pos2))]
  } else {
    resol <-
      data[, unique(abs(pos2 - pos1))] %>% purrr::keep(function(x)
        x > 0) %>% min()
  }
  
  resol <- as.integer(resol)
  assert_that(rlang::is_scalar_integer(resol))
  assert_that(resol > 0)
  resol
}


#' Load Hi-C dataset from file
#' 
#' @description 
#' This is the gateway function to load Hi-C files in a variety of formats:
#' Juicer short, Juicer dump, .hic, BEDPE (aka genbed), etc. For each format, the argument specification may be slightly different. For details, refer to the following:
#' 
#' * [load_juicer_hic()]
#' * [load_hic_genbed()]
#'
#' @export
load_hic <-
  function(file_path,
           format = c("auto", "juicer_short", "juicer_dump", "juicer_hic", "genbed", "cool"),
           genome,
           resol = NULL,
           chrom = NULL,
           sample = NULL,
           type = c("observed", "oe", "expected", "pearson", "cofrag"),
           norm = c("NONE", "KR", "VC", "VC_SQRT", "SCALE"),
           ...) {
    # The underlying C function can't deal with paths like "~/some_path/some_file.hic"
    # Need obtain the "canonical" path
    file_path <- normalizePath(file_path)
    assert_that(assertthat::is.readable(file_path))
    assert_that(is_scalar_character(genome) &&
                  !is_null(bedtorch::get_seqinfo(genome)))
    format <- match.arg(format)
    type <- match.arg(type)
    norm <- match.arg(norm)
    
    mf = match.call(expand.dots = TRUE)
    mf$format <- NULL
    mf$type <- type
    mf$norm <- norm
    
    if (format == "auto") {
      format <- guess_format(file_path)
    }
    if (format == "juicer_short") {
      mf[[1L]] <- quote(hictools::load_juicer_short)
    } else if (format == "juicer_dump") {
      mf[[1L]] <- quote(hictools::load_juicer_dump)
    } else if (format == "juicer_hic") {
      mf[[1L]] <- quote(hictools::load_juicer_hic)
    } else if (format == "genbed") {
      mf[[1L]] <- quote(hictools::load_hic_genbed)
    } else if (format == "cool") {
      mf[[1L]] <- quote(hictools::load_hic_coll)
    } else {
      stop(str_interp("Invalid format ${format}"))
    }
    
    eval.parent(mf)
  #   
  #   m <- match.call(expand.dots = FALSE)
  #   if (is.matrix(eval.parent(m$data)))  m$data <- as.data.frame(data, stringsAsFactors = TRUE)
  #   m$... <- m$contrasts <- NULL
  #   
  #   check_na_conflict(match.call(expand.dots = TRUE))
  #   
  #   ## Look for missing `na.action` in call. To make the default (`na.fail`)
  #   ## recognizable by `eval.parent(m)`, we need to add it to the call
  #   ## object `m`
  #   
  #   if(!("na.action" %in% names(m))) m$na.action <- quote(na.fail)
  #   
  #   # do we need the double colon here?
  #   m[[1]] <- quote(stats::model.frame)
  #   m <- eval.parent(m)
  #   
  #   
  # 
  # 
  # 
  # if (format == "auto") {
  #   format <- guess_format(file_path)
  # }
  # if (format == "juicer_short") {
  #   data <- load_juicer_short(file_path, ...)
  # } else if (format == "juicer_dump") {
  #   data <- load_juicer_dump(file_path, ...)
  # } else if (format == "juicer_hic") {
  #   data <- load_juicer_hic(file_path, ...)
  # } else if (format == "genbed") {
  #   data <- load_hic_genbed(file_path = file_path, ...)
  # } else if (format == "cool") {
  #   data <- load_hic_cool(file_path = file_path, ...)
  # } else {
  #   stop(str_interp("Invalid format ${format}"))
  # }
  # data
}



#' Dump a Hi-C object as .hic format
#'
#' This function invokes Juicer tools for the dumping
#' @param hic_matrix A Hi-C object
#' @param file_path Path to the output .hic file
#' @param java Path to JVM. Default is \code{java}
#' @param ref_genome Reference genome \code{hic_matrix} is using. Default is \code{hg19}
#' @param norm Calculate specific normalizations. Default is VC,VC_SQRT,KR,SCALE
#' @export
write_juicer_hic <-
  function(hic_matrix,
           file_path,
           juicertools = get_juicer_tools(),
           java = "java",
           norm = c("NONE", "VC", "VC_SQRT", "KR", "SCALE")) {
    norm <- match.arg(norm, several.ok = TRUE)
    norm <- paste(norm, collapse = ",")
    
    
    ref_genome <- get_juicer_genome(hic_genome(hic_matrix))
    
    # Usually, it doesn't make sense to write the Hi-C data if it is not observed/NONE)
    hic_type <- attr(hic_matrix, "type")
    hic_norm <- attr(hic_matrix, "norm")
    
    # if (!isTRUE(hic_type == "observed" && hic_norm == "NONE"))
    #   warning("Hi-C data is not observed/NONE")

    juicer_short_path <- tempfile(fileext = ".short")
    on.exit(unlink(juicer_short_path), add = TRUE)

    write_juicer_short(hic_matrix, file_path = juicer_short_path)

    resol <- attr(hic_matrix, "resol")
    assert_that(is_valid_resol(resol))
    resol_list <- keep(allowed_resol(), ~ . >= resol) %>% paste(collapse = ",")
    
    cmd <-
      str_interp("${java} -jar ${juicertools} pre -r ${resol_list} -k ${norm} ${juicer_short_path} ${file_path} ${ref_genome}")
    logging::loginfo(cmd)
    retcode <- system(cmd)
    if (retcode != 0) {
      stop(str_interp("Error in creating .hic , RET: ${retcode}, CMD: ${cmd}"))
    }
  }


#' @export
write_juicer_short <- function(hic_matrix, file_path) {
  # 0 22 16000000 0 0 22 16000000 1 95
  hic_matrix[, .(str1 = 0,
                 chrom1,
                 pos1,
                 frag1 = 0,
                 str2 = 0,
                 chrom2,
                 pos2,
                 frag2 = 1,
                 score)] %>%
    na.omit() %>%
    data.table::fwrite(file = file_path, col.names = FALSE, sep = " ")
  # hic_matrix %>%
  #   mutate(str1 = 0, frag1 = 0, str2 = 0, frag2 = 1) %>%
  #   select(str1, chrom1, pos1, frag1, str2, chrom2, pos2, frag2, score) %>%
  #   na.omit() %>%
  #   write_delim(file = file_path, col_names = FALSE, delim = " ")
}

#' Write the Hi-C dataset to disk in bedtorch table format
#' 
#' 
#' @export
write_hic_bedtorch <- function(hic_matrix, file_path, comments = NULL) {
  assert_that(is(hic_matrix, "ht_table"))
  assert_that(is_scalar_character(file_path))
  assert_that(is_null(comments) || is_character(comments))
  
  resol <- attr(hic_matrix, "resol")
  assert_that(is_scalar_integer(resol) && resol > 0)
  
  norm <- attr(hic_matrix, "norm")
  assert_that(is_scalar_character(norm))
  
  type <- attr(hic_matrix, "type")
  assert_that(is_scalar_character(type))
  
  genome <- attr(hic_matrix, "genome")
  assert_that(is_null(genome) || is_scalar_character(genome))
  
  user_comments <- comments
  create_time <- lubridate::now() %>% format("%Y-%m-%dT%H:%M:%S%z")
  hictools_version <- packageVersion("hictools")
  comments <- c(
    str_interp("create_time=${create_time}"),
    str_interp("resolution=${resol}"),
    str_interp("type=${type}"),
    str_interp("norm=${norm}")
  )
  if (!is_null(genome))
    comments <- c(comments, str_interp("genome=${genome}"))
  
  comments <- c(
    comments,
    str_interp("hictools_version=${hictools_version}"),
    user_comments
  )
  
  hic_matrix <- local({
    meta_fields <- colnames(hic_matrix) %>% tail(n = -5)
    
    dt1 <- hic_matrix[, .(
      chrom = chrom1,
      start = pos1,
      end = pos1 + resol,
      chrom2,
      start2 = pos2,
      end2 = pos2 + resol,
      score = score
    )]
    
    dt2 <- hic_matrix[, ..meta_fields]
    cbind(dt1, dt2)
  }) %>% bedtorch::as.bedtorch_table()
  
  bedtorch::write_bed(hic_matrix, file_path = file_path, comments = comments)
}


convert_matrix_hic <- function(mat, chrom, resol, pos_start, ...) {
  stopifnot(nrow(mat) == ncol(mat))
  dim <- nrow(mat)
  stopifnot(length(chrom) == 1)
  stopifnot(length(resol) == 1 & resol > 0)

  all_pos <- (1:dim - 1) * resol + pos_start
  expand_grid(pos1 = all_pos,
              pos2 = all_pos) %>%
    mutate(
      chrom1 = chrom,
      chrom2 = chrom,
      pos1 = as.integer(pos1),
      pos2 = as.integer(pos2),
      score = as.numeric(mat)
    ) %>%
    filter(pos1 <= pos2) %>%
    na.omit() %>%
    set_attr("resol", resol) %>%
    select(chrom1, pos1, chrom2, pos2, score) %>%
    ht_table(resol = resol, ...)
}

#' Convert a Hi-C map to a naive matrix
#' 
#' @param missing_score Scores where the bin does not contain any signal.
#' @param full_matrix Logical value indicating whether to build the matrix from
#'   position 0
#' @export
convert_hic_matrix <-
  function(hic_matrix,
           chrom = NULL,
           missing_score = NA,
           full_matrix = FALSE) {
    
  if (is.null(chrom)) {
    # Infer chrom from input
    chrom <- unique(c(as.character(hic_matrix$chrom1), as.character(hic_matrix$chrom2)))
    stopifnot(length(chrom) == 1)
  }

  resol <- attr(hic_matrix, "resol")
  stopifnot(resol > 0)

  # Single-chromosome matrix
  hic_matrix <- hic_matrix[chrom1 == chrom & chrom2 == chrom]
  if (full_matrix)
    min_pos <- 0
  else
    min_pos <- min(c(hic_matrix$pos1, hic_matrix$pos2))
  max_pos <- max(c(hic_matrix$pos1, hic_matrix$pos2))
  hic_matrix[, `:=`(x = (pos1 - min_pos) %/% resol + 1,
                    y = (pos2 - min_pos) %/% resol + 1)]


  mat_dim <- (max_pos - min_pos) %/% resol + 1
  mat <- matrix(rep(missing_score, mat_dim * mat_dim), nrow = mat_dim)
  mat[hic_matrix[, .(x, y)] %>% as.matrix()] <- hic_matrix$score
  mat[hic_matrix[, .(y, x)] %>% as.matrix()] <- hic_matrix$score


  # mat[hic_matrix %>% select(x, y) %>% as.matrix()] <- hic_matrix$score
  # mat[hic_matrix %>% select(y, x) %>% as.matrix()] <- hic_matrix$score

  mat_pos <- (1:mat_dim - 1) * resol + min_pos
  mat_header <- mat_pos %>% map_chr(~ str_interp("chr${chrom}-$[d]{.}"))
  colnames(mat) <- mat_header
  rownames(mat) <- mat_header
  mat
}


#' @export
write_hic_matrix <- function(mat, file_path, chrom = NULL) {
  # Detect all-NA rows/columns
  na_band <- apply(
    mat,
    MARGIN = 1,
    FUN = function(v)
      all(is.na(v))
  )
  mat <- mat[!na_band,!na_band]

  header <- paste(c("", colnames(mat)), collapse = "\t")
  body <- 1:nrow(mat) %>% map_chr(function(idx) {
    pos_str <- colnames(mat)[idx]
    row_str <- paste(mat[idx,], collapse = "\t")
    paste0(pos_str, "\t", row_str)
  })
  c(header, body) %>% write_lines(file = file_path)
}


#' Dump Hi-C data as .cool
#' @export
write_cool <- function(hic_matrix, file_path, juicertools, java = "java", executable = "hicConvertFormat") {
  # First write as as a temporary genbed file, then call hicConvertFormat
  temp_hic <- tempfile(fileext = ".hic")

  tryCatch({
    resol <- attr(hic_matrix, "resol")
    hic_matrix %>%
      write_juicer_hic(file_path = temp_hic,
                      juicertools = juicertools,
                      java = java)

    # Output name
    # For single resolution .cool dataset, hicConvertFormat will implicit change the output
    # file name. For example: foo.cool -> foo_500000.cool
    output_name <- str_interp("${str_sub(file_path, end = -6L)}_${resol}.cool")

    cmd <- str_interp(
      paste0(
        "${executable} -m ${temp_hic} --inputFormat hic ",
        "-r ${resol} ",
        "-o ${file_path} --outputFormat cool"
      )
    )
    cat(cmd, "\n")
    system(cmd)
    file.rename(output_name, file_path)
  }, finally = {
    unlink(temp_hic)
  })
}


#' Dump Hi-C data to file
#'
#' @export
write_hic <- function(hic_matrix, file_path, format = NULL, ...) {
  if (is.null(format)) {
    format <- guess_format(file_path)
  }
  if (format == "juicer_short") {
    write_juicer_short(hic_matrix, file_path)
  } else if (format == "juicer_hic") {
    write_juicer_hic(hic_matrix, file_path, ...)
  } else if (format == "genbed") {
    write_hic_genbed(hic_matrix, file_path)
  } else {
    stop(str_interp("Invalid format ${format}"))
  }
}
