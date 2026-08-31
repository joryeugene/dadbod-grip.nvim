-- lazy.nvim package spec: auto-read and merged into the user's plugin spec.
-- Declares all commands as lazy-load triggers so any :Grip* command works
-- without requiring the user to manually maintain a cmd list.
-- The GitHub path as the first element is required: name= alone is not a valid
-- plugin identifier in all lazy.nvim versions. optional=true prevents lazy from
-- trying to install this from GitHub when the user already has dir="..." set.
return {
  {
    "joryeugene/dadbod-grip.nvim",
    optional = true,
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
      "GripImport",
      "GripAttach",
      "GripDetach",
      "GripOpen",
      "GripToggle",
      "GripFill",
    },
  },
}
