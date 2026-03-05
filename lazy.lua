-- lazy.nvim package spec: auto-read and merged into the user's plugin spec.
-- Declares all commands as lazy-load triggers so any :Grip* command works
-- without requiring the user to manually maintain a cmd list.
return {
  cmd = {
    "Grip",
    "GripStart",
    "GripHome",
    "GripConnect",
    "GripSchema",
    "GripTables",
    "GripQuery",
    "GripSave",
    "GripLoad",
    "GripHistory",
    "GripProfile",
    "GripExplain",
    "GripAsk",
    "GripDiff",
    "GripCreate",
    "GripDrop",
    "GripRename",
    "GripProperties",
    "GripExport",
    "GripAttach",
    "GripDetach",
  },
}
