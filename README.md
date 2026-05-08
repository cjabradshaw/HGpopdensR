# HGpopdensR

R translation of the Australia-wide hunter-gatherer population estimate pipeline from `HGpopdens`.

## Contents

- `Source/estimate_australia.R`: R implementation of the Australia-wide estimate
- `INPUT/AUS.geojson`: Australia polygon used for area-weighted intersections
- `OUTPUT/globe_S0.nc`, `OUTPUT/globe_S1.nc`, `OUTPUT/globe_S2.nc`: bundled FORGE global outputs copied from `HGpopdens`
- `OUTPUT/Australia_population_estimate.txt`: generated summary report

## Requirements

Install the required R packages:

```r
install.packages(c("ncdf4", "sf", "lwgeom"))
```

## Usage

From the repository root:

```bash
Rscript Source/estimate_australia.R
```

This writes `OUTPUT/Australia_population_estimate.txt`.

Optional arguments:

```bash
Rscript Source/estimate_australia.R --scenario S2
Rscript Source/estimate_australia.R --ci-level 0.95 --density-cv 0.7
Rscript Source/estimate_australia.R --output-dir OUTPUT --country-geojson INPUT/AUS.geojson
```

## Current default assumptions

- The preferred run is `S2`.
- The 95% confidence interval is based on **density uncertainty**, not scenario spread.
- The default density uncertainty assumption is **SD = 0.7 x mean density**, following the requested use of **Bradshaw et al. 2021** (`doi:10.1038/s41467-021-21551-3`).
- The CI is computed with a **lognormal** distribution so the population total remains positive.
