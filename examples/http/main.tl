local http = require("socket.http")
local ltn12 = require("ltn12")

local body: {string} = {}
local _, code = http.request{
   url = "http://example.com/",
   sink = ltn12.sink.table(body),
}
print("status:", code)
local text = table.concat(body)
print("bytes:", #text)
print(text:sub(1, 60))
