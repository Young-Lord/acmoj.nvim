if vim.g.loaded_acmoj_plugin == 1 then
  return
end
vim.g.loaded_acmoj_plugin = 1

require("acmoj").setup()
