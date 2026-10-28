# transport-graph

Test project whose goal is to build a non-trivial application using OCaml and
the [neodriver](https://opam.ocaml.org/packages/neodriver/) library to interact
with a [Neo4j](https://neo4j.com) database.

The project consumes public transit connection data stored as files conforming
to the [GTFS Schedule](https://gtfs.org/schedule/reference/) standard. The
sample data bundled with the project contains public transit connections in
Sweden, downloaded from <https://mobilitydatabase.org>.

## Graph design

The model of the graph loaded into Neo4j — its nodes, relationships, and their
properties — is described in [docs/graph-design.md](docs/graph-design.md).

## Executables

The project provides two executables:

- `load_data` — reads GTFS files, parses them, and loads the data into a Neo4j
  database
- `find_connection` — takes the names of two stops on input and prints the best
  connection found between them

## Building

The project uses [Dune](https://dune.build) as its build system and
[opam](https://opam.ocaml.org) for dependency management.

```sh
opam install . --deps-only
dune build
```

## Usage

Both executables read the Neo4j connection settings from `--url`, `--user`,
`--password` and `--database`, falling back to the `NEO4J_URL`,
`NEO4J_USERNAME`, `NEO4J_PASSWORD` and `NEO4J_DATABASE` environment
variables (an empty value counts as unset; the user and the database default
to `neo4j`). Run either executable with `--help` for details.

```sh
# Load GTFS data into Neo4j
dune exec bin/load_data.exe -- --data gtfs.zip

# Find the best connection between two stops
dune exec bin/find_connection.exe -- --from "Stockholm C" --to "Uppsala C"
```

## Testing

```sh
dune test
```

## License

This project is licensed under the [BSD 3-Clause License](LICENSE).
