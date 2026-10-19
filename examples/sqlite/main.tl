local sqlite3 = require("lsqlite3")

local db = sqlite3.open_memory()
db:exec("CREATE TABLE nums (n INTEGER); INSERT INTO nums VALUES (1), (2), (3);")
for row in db:nrows("SELECT n FROM nums ORDER BY n") do
   print("n =", row["n"])
end
db:close()
print("sqlite3 module bundled from C library")
