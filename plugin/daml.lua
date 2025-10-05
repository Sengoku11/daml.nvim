-- Runs once when the plugin is loaded (by any loader).
-- We defer to UiEnter to avoid slowing startup, then call default setup().
if vim.g.loaded_daml_nvim then
  return
end
vim.g.loaded_daml_nvim = true

-- Defer to after UI is up for better performance, then to the main setup with defaults.
vim.api.nvim_create_autocmd('UiEnter', {
  once = true,
  callback = function()
    -- Only run if user hasn't called require('daml').setup() themselves yet
    if not vim.g._daml_nvim_user_setup_done then
      require('daml').setup()
    end
  end,
})
