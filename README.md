# PSCOPF

All the following commands are executed in the julia REPL
after launching it at the project's root directory with the project environment activated,
which should set up all required packages.
So, to start, you need to execute :

```
julia --project=.
```

## Build Docs

To build the documentation. Run :

```
include("docs/make.jl")
```

The documentation will be built at `docs/build` and can be viewed by opening the file `docs/build/index.html` in a web browser.

## Launch Tests

Enter package mode by pressing "]", then, launch :

```
test
```

To return to julia mode, simply press backspace (as if you were deleting the "]" you pressed).

## Generate a network instance

the file `main_generate_instance.jl` can be used for this purpose.
It will create a PSCOPF instance using the julia API.
Then, the instance will be written to `data/2buses_small_usecase/generate_instance`, by default.

It can be launched in the julia REPL using :
```
include("src_mains/main_generate_instance.jl")
```

You can change the functions `create_network` or `create_init_state` to modify the instance.

## Generate Uncertainties

The instance generated in the previous section is not enough to launch PSCOPF.
PSCOPF needs information about the injecions uncertainties.
Therefore, the need for the `pscopf_uncertainties.txt` file.

the file `main_generate_uncertainties.jl`
reads a description of the uncertainties from the file `uncertainties_distribution.txt`,
as well as input data describing a network
(like the ones generated by `main_generate_instance.jl`).
By default, the input is read from `data/2buses_small_usecase/`.

Then, it writes a full PSCOPF instance to `data/2buses_small_usecase/generate_uncertainties`

## Generate a PTDF

A julia module separate from PSCOPF, is implemented in `src/PTDF.jl`.
The script `main_ptdf.jl` allows to compute a ptdf matrix using this module.
It reads a network description (different from that of PSCOPF).
It then, outputs a ptdf matrix file compatible with PSCOPF's input.

The directory `data/ptdf` contains input files, providing a sample for `main_ptdf.jl`'s input format.