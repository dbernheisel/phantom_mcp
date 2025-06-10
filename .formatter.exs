# Used by "mix format"
[
  export: [
    locals_without_parens: [
      tool: 2,
      tool: 3,
      prompt: 2,
      prompt: 3,
      resource: 3,
      resource: 4
    ]
  ],
  import_deps: [:phoenix],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
