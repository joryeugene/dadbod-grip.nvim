-- Independent native-profile inputs, not a parser or a copy of production rules.
return {
  ordinary = {
    { id = "ordinary ENUM", definition = "ENUM('pending','active','disabled')",
      values = "(1,3,'one'),(2,'invalid','two')", numeric = { "3", "0" } },
    { id = "ordinary SET", definition = "SET('read','write','admin')",
      values = "(1,5,'one'),(2,0,'two')", numeric = { "5", "0" } },
  },
  ambiguous = {
    { id = "duplicate ENUM", definition = "ENUM('a','a')", values = "(1,1,'one'),(2,2,'two')" },
    { id = "duplicate SET", definition = "SET('a','a')", values = "(1,1,'one'),(2,2,'two')" },
    { id = "case-equivalent ENUM", definition = "ENUM('a','A') CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci",
      values = "(1,1,'one'),(2,2,'two')" },
    { id = "case-equivalent SET", definition = "SET('a','A') CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci",
      values = "(1,1,'one'),(2,2,'two')" },
  },
  escaped = {
    { id = "quoted ENUM member", definition = "ENUM('can''t','ok')", values = "(1,1,'one'),(2,2,'two')" },
    { id = "backslash SET member", definition = [[SET('a\b','ok')]], values = "(1,1,'one'),(2,2,'two')" },
  },
}
