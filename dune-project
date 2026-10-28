(lang dune 3.13)

(name transport_graph)

(generate_opam_files true)

(package
 (name transport_graph)
 (synopsis "Transport graph")
 (description "Transport graph project")
 (depends
  (ocaml
   (>= 5.2.0))
  (neodriver
   (>= 0.9.0))
  (cmdliner
   (>= 2.1))
  (camlzip
   (>= 1.14))
  (ppx_marshal
   (>= 0.6))
  (gendarme
   (>= 0.6))
  (gendarme-csv
   (>= 0.6))))
