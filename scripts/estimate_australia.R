## Estimates the total hunter-gatherer population in Australia from Zhu et al. (2021; doi:10.1038/s41559-021-01548-3)
## by intersecting the country polygon with the global population density outputs from the bundled
## FORGE NetCDF files. It computes area-weighted totals and can optionally provide a confidence interval
## based on an assumed coefficient of variation for density.

## set working directory
setwd("~/Documents/GitHub/HGpopdensR/")

suppressPackageStartupMessages({
  library(ncdf4)
  library(sf)
  library(lwgeom)
})

scenario_descriptions <- c(
  S0 = "FORGE forced directly by ORCHIDEE outputs",
  S1 = "S0 with daily NPP scaled so annual NPP matches MODIS in each grid cell",
  S2 = "observation-based daily NPP seasonality and plant decay; Zhu et al. (2021) treat this as the preferred run"
)

cv_source <- "Bradshaw et al. 2021, doi:10.1038/s41467-021-21551-3 &
              Lourandos, H. Continent of Hunter-Gatherers: New Perspectives in Australian Prehistory.
              (Cambridge University Press, 1997)"

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path(getwd(), "scripts", "estimate_australia.R")
}
root_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE)

parse_args <- function() {
  defaults <- list(
    output_dir = file.path(root_dir, "OUTPUT"),
    country_geojson = file.path(root_dir, "INPUT", "AUS.geojson"),
    report_file = file.path(root_dir, "OUTPUT", "Australia_population_estimate.txt"),
    scenario = "all",
    ci_level = 0.95,
    density_cv = 0.7
  )

  args <- commandArgs(trailingOnly = TRUE)
  i <- 1
  while (i <= length(args)) {
    arg <- args[[i]]
    if (!startsWith(arg, "--")) {
      stop(sprintf("unexpected argument: %s", arg), call. = FALSE)
    }

    if (grepl("=", arg, fixed = TRUE)) {
      parts <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
      key <- parts[[1]]
      value <- paste(parts[-1], collapse = "=")
    } else {
      key <- sub("^--", "", arg)
      if (i == length(args)) {
        stop(sprintf("Missing value for --%s", key), call. = FALSE)
      }
      value <- args[[i + 1]]
      i <- i + 1
    }

    if (!(key %in% c("output-dir", "country-geojson", "report-file", "scenario", "ci-level", "density-cv"))) {
      stop(sprintf("Unknown option: --%s", key), call. = FALSE)
    }

    if (key == "output-dir") defaults$output_dir <- value
    if (key == "country-geojson") defaults$country_geojson <- value
    if (key == "report-file") defaults$report_file <- value
    if (key == "scenario") defaults$scenario <- value
    if (key == "ci-level") defaults$ci_level <- as.numeric(value)
    if (key == "density-cv") defaults$density_cv <- as.numeric(value)

    i <- i + 1
  }

  if (!(defaults$scenario %in% c("S0", "S1", "S2", "all"))) {
    stop("--scenario must be one of: S0, S1, S2, all", call. = FALSE)
  }
  if (!is.finite(defaults$ci_level) || defaults$ci_level <= 0 || defaults$ci_level >= 1) {
    stop("--ci-level must be between 0 and 1", call. = FALSE)
  }
  if (!is.finite(defaults$density_cv) || defaults$density_cv < 0) {
    stop("--density-cv must be non-negative", call. = FALSE)
  }

  defaults
}

infer_step <- function(values, fallback = 2.0) {
  arr <- as.numeric(values)
  arr <- arr[is.finite(arr)]
  if (length(arr) < 2) {
    return(fallback)
  }
  diffs <- abs(diff(arr))
  diffs <- diffs[diffs > 0]
  if (length(diffs) == 0) {
    return(fallback)
  }
  as.numeric(stats::median(diffs))
}

scenario_order <- function(scenario) {
  if (identical(scenario, "all")) {
    return(c("S0", "S1", "S2"))
  }
  scenario
}

rect_polygon <- function(xmin, ymin, xmax, ymax) {
  st_polygon(list(matrix(
    c(
      xmin, ymin,
      xmax, ymin,
      xmax, ymax,
      xmin, ymax,
      xmin, ymin
    ),
    ncol = 2,
    byrow = TRUE
  )))
}

compute_population_total <- function(netcdf_path, country_geom) {
  nc <- nc_open(netcdf_path)
  on.exit(nc_close(nc), add = TRUE)

  lats <- ncvar_get(nc, "lat")
  lons <- ncvar_get(nc, "lon")
  hum_popu <- ncvar_get(nc, "hum_popu")
  units <- ncatt_get(nc, "hum_popu", "units")$value

  dlat <- infer_step(lats, 2.0)
  dlon <- infer_step(lons, 2.0)

  grid <- expand.grid(lon = as.numeric(lons), lat = as.numeric(lats), KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  grid$density <- as.vector(hum_popu)
  grid$cell_id <- seq_len(nrow(grid))
  grid <- grid[is.finite(grid$density), , drop = FALSE]

  cell_geoms <- lapply(seq_len(nrow(grid)), function(i) {
    rect_polygon(
      grid$lon[[i]] - dlon / 2,
      grid$lat[[i]] - dlat / 2,
      grid$lon[[i]] + dlon / 2,
      grid$lat[[i]] + dlat / 2
    )
  })

  cells_sf <- st_sf(
    cell_id = grid$cell_id,
    lon = grid$lon,
    lat = grid$lat,
    density = grid$density,
    geometry = st_sfc(cell_geoms, crs = 4326)
  )

  overlaps <- suppressWarnings(suppressMessages(st_intersection(cells_sf, country_geom)))
  if (nrow(overlaps) == 0) {
    stop(sprintf("no Australia overlap found in %s", netcdf_path), call. = FALSE)
  }

  overlap_areas <- as.numeric(lwgeom::st_geod_area(overlaps))
  total_people <- sum(overlaps$density * overlap_areas)
  total_area <- sum(overlap_areas)

  list(
    scenario = sub("^globe_", "", tools::file_path_sans_ext(basename(netcdf_path))),
    netcdf = normalizePath(netcdf_path, winslash = "/", mustWork = TRUE),
    units = units,
    total_people = total_people,
    country_area_m2 = total_area,
    mean_density_per_100km2 = total_people / (total_area / 1e8),
    overlapping_cells = length(unique(overlaps$cell_id))
  )
}

load_results <- function(output_dir, country_geojson, report_scenarios) {
  suppressMessages(sf_use_s2(FALSE))
  country_geom <- st_read(country_geojson, quiet = TRUE)
  country_geom <- st_make_valid(st_transform(country_geom, 4326))

  lapply(report_scenarios, function(scenario) {
    netcdf_path <- file.path(output_dir, sprintf("globe_%s.nc", scenario))
    if (!file.exists(netcdf_path)) {
      stop(sprintf("missing NetCDF file: %s", netcdf_path), call. = FALSE)
    }
    compute_population_total(netcdf_path, country_geom)
  })
}

compute_density_ci_from_cv <- function(total_people, ci_level, density_cv) {
  z_score <- qnorm(0.5 + ci_level / 2)
  sigma2_log <- log1p(density_cv^2)
  sigma_log <- sqrt(sigma2_log)
  mu_log <- log(total_people) - 0.5 * sigma2_log

  list(
    ci_level = ci_level,
    density_cv = density_cv,
    sigma_log = sigma_log,
    mu_log = mu_log,
    z_score = z_score,
    lower = exp(mu_log - z_score * sigma_log),
    upper = exp(mu_log + z_score * sigma_log)
  )
}

format_result_line <- function(result) {
  sprintf(
    "%2s  %15s people  %8.2f per 100 km^2  %3d intersecting cells",
    result$scenario,
    format(round(result$total_people), big.mark = ",", scientific = FALSE, trim = TRUE),
    result$mean_density_per_100km2,
    result$overlapping_cells
  )
}

build_report <- function(results, country_geojson, density_ci = NULL) {
  result_names <- vapply(results, function(x) x$scenario, character(1))
  preferred <- if ("S2" %in% result_names) {
    results[[match("S2", result_names)]]
  } else {
    results[[1]]
  }

  lines <- c(
    "Australia-wide 'hunter-gatherer' (non-agropastoralist) population estimate from bundled FORGE outputs",
    "",
    sprintf("country polygon: %s", normalizePath(country_geojson, winslash = "/", mustWork = TRUE)),
    "population variable: hum_popu (human population density, ind/m2)",
    "",
    "logical steps used for the estimate:",
    "1. Load Australia country polygon from bundled GeoJSON file",
    "2. Open each global NetCDF output and read lat, lon, hum_popu",
    "3. Treat each grid-cell centre as representing a full 2°×2° cell",
    "4. Intersect each grid cell with the Australia polygon to keep only the in-country area",
    "5. Compute WGS84 geodetic area of that cell-country overlap",
    "6. Multiply hum_popu (ind/m2) by overlap area (m2) to convert density to number of people",
    "7. Sum over all overlapping cells to obtain the Australia-wide population total",
    "8. Report the requested scenario outputs and treat S2 as the preferred estimate because Zhu et al. (2021)",
    "   noted that S0 and S1 unrealistically omit many hunter-gatherers from interior Australia."
  )

  if (!is.null(density_ci)) {
    ci_percent <- density_ci$ci_level * 100
    lines <- c(
      lines,
      "9. Assume the standard deviation of density is 70% of mean density, following the",
      sprintf(" assumption based on %s.", cv_source),
      "10. Assume Australia-wide total inherits same relative uncertainty as density",
      "11. Convert that coefficient of variation into a log-Normal distribution so interval remains",
      sprintf("    positive, then extract the central %.0f%% interval.", ci_percent)
    )
  }

  lines <- c(lines, "", "scenario definitions from the paper:")
  for (scenario in c("S0", "S1", "S2")) {
    if (scenario %in% result_names) {
      lines <- c(lines, sprintf("- %s: %s", scenario, scenario_descriptions[[scenario]]))
    }
  }

  lines <- c(
    lines,
    "",
    "Australia totals:",
    "run  total population     mean density        coverage",
    vapply(results, format_result_line, character(1)),
    "",
    sprintf(
      "preferred estimate: %s = %s people (%.2f people per 100 km^2).",
      preferred$scenario,
      format(round(preferred$total_people), big.mark = ",", scientific = FALSE, trim = TRUE),
      preferred$mean_density_per_100km2
    )
  )

  if (!is.null(density_ci)) {
    ci_percent <- density_ci$ci_level * 100
    lines <- c(
      lines,
      sprintf(
        "approximate %.0f%% confidence interval for S2: %s to %s people.",
        ci_percent,
        format(round(density_ci$lower), big.mark = ",", scientific = FALSE, trim = TRUE),
        format(round(density_ci$upper), big.mark = ",", scientific = FALSE, trim = TRUE)
      ),
      sprintf(
        "confidence interval method: log-Normal interval with density SD = %.2f × mean density.",
        density_ci$density_cv
      ),
      sprintf(
        "derived log-space SD = %.3f from coefficient of variation %.2f.",
        density_ci$sigma_log,
        density_ci$density_cv
      ),
      sprintf("assumption source: %s.", cv_source)
    )
  }

  lines <- c(
    lines,
    "",
    "Notes:",
    "- Bundled outputs contain 1 equilibrated annual time slice per scenario",
    "- Estimate is area-weighted by true Australia/cell intersection, not by cell centres alone"
  )

  if (is.null(density_ci)) {
    lines <- c(lines, "- No confidence interval computed because S2 not included in the requested output.")
  } else {
    lines <- c(
      lines,
      "- confidence interval based on uncertainty in underlying density estimate, not on",
      "  differences between S0/S1/S2 scenarios",
      "- point estimate treated as mean of positive-valued total-population distribution",
      "- using a log-Normal distribution, interval is asymmetric on original population",
      "  scale even though it is symmetric in log space"
    )
  }

  paste(lines, collapse = "\n")
}

main <- function() {
  args <- parse_args()
  results <- load_results(args$output_dir, args$country_geojson, scenario_order(args$scenario))

  density_ci <- NULL
  scenarios <- vapply(results, function(x) x$scenario, character(1))
  if ("S2" %in% scenarios) {
    s2_total <- results[[match("S2", scenarios)]]$total_people
    density_ci <- compute_density_ci_from_cv(s2_total, args$ci_level, args$density_cv)
  }

  report <- build_report(results, args$country_geojson, density_ci)
  dir.create(dirname(args$report_file), recursive = TRUE, showWarnings = FALSE)
  writeLines(report, args$report_file, useBytes = TRUE)
  cat(report, "\n", sep = "")
}

main()
