{
  description = "Synthetic instance for the pins engine tests";

  inputs = {
    nixpkgs.url = "github:example/nixpkgs/d93fc7d10ddf5b30a89848233f527f483a0d886f";
    example-term.url = "github:example/example-term/v1.2.0";
    dotsteward.url = "github:example/dotsteward/v0.1.0";
    example-follow.follows = "dotsteward/nixpkgs";
  };

  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
