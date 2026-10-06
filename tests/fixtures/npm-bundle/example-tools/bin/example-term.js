#!/usr/bin/env node
// Synthetic command of the npm-bundle fixture: prints its name and version,
// or PATH with --path.
"use strict";
if (process.argv[2] === "--path") {
  console.log(process.env.PATH);
} else {
  console.log("example-term 1.2.3");
}
