MUHYIDDIN SCHOOL WEBSITE MANAGER
================================

Start: double-click "Launch Website Manager.bat".

The manager edits the existing website files and folder structure:
  - Gallery: add an event album, preview and select its cover, manually arrange albums, unlist albums while retaining their files, or delete albums after making a recoverable backup.
  - Latest Updates: add, edit, reorder, or remove homepage update cards.
  - Forms, Documents, Policies: edit bilingual section titles and links, add or remove sections and entries, and copy new files into the existing folders.
  - Short Links: create and edit redirects in the website's l folder, save an internal purpose note, or delete a link with a recoverable backup.

Short link descriptions are stored in short-links.json inside this tool folder;
redirect pages keep the existing l/<folder>/index.html format. The global
Undo delete button can restore the most recently deleted short link during
the current manager session. The Short Links tab shows folder names and the
full https://muhyiddin.edu.mv/l/<folder>/ address, with a copy button.

Before replacing an HTML file, the manager creates a timestamped copy under
Backups. Activity is shown in the window and saved under Logs.

Moving albums and choosing "Save order" safely renumbers their folders so the
existing numbered-folder gallery format and its updater agree on the order.
Unlisted folders are recorded in gallery-unlisted.txt and kept on disk; select
one and choose "List album" to restore it. Both the manager and the existing
gallery update script honor the unlisted list. Deleting an album first copies
the full folder into Backups/DeletedAlbums. Reordering changes album folder
numbers and URLs; links inside the website are updated automatically.

The manager is designed for Windows PowerShell and the existing website folder.
Keep the whole MUHYIDDIN_WEBSITE_MANAGER_TOOL folder in the website root.
