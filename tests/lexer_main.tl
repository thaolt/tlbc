-- require("this_module_does_not_exist")
--[=[ require("also_nonexistent") ]=]
local quoted = "require('phantom')"
local long_quoted = [=[ require("ghost") ]=]
local function dummy(_name: string): string
   return "method"
end
local example = {require = dummy}
local ignored = example.require("not_a_module")
local a = require("counter")
local b = require 'counter'
local mymath = require("mymath")
print(a.value, b.value, quoted ~= "", long_quoted ~= "", ignored, mymath.add(19, 23))
