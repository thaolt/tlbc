local greet = require("greeter")
local config = require("config")
local legacy = require("legacy")

print(greet("world"))
print("greeting sourced from", config.origin())
print(legacy.motto())
