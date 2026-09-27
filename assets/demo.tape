# The README demo. Render with `mise run demo`; see CONTRIBUTING.md.
#
# Records your own Neovim config and the agentcomplete it installs, so re-render after
# updating the plugin there. assets/demo.sh stages the prompt buffer and the last message.

Output assets/demo.gif

Require nvim

Set Shell "bash"
Set FontFamily "Berkeley Mono, Symbols Nerd Font Mono"
Set FontSize 16
# Wide enough that the context pane sits beside the prompt (context.min_width = 160).
Set Width 1800
Set Height 760
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 45ms
Set Framerate 24

Hide
Type "assets/demo.sh"
Enter
Wait+Screen@20s /read-only/
# Entering insert mode repaints the whole screen, which vhs captures as a blank frame.
Type "i"
Sleep 1s
Show

Sleep 2.5s
Type "Add the test first. Use "
Type "/td"
Sleep 1.5s
Tab
Sleep 400ms
Enter
Type " to write a failing case in "
Type "@tests/lay"
Sleep 1.5s
Tab
Sleep 400ms
Enter
Type " that crosses the min_width boundary, then make "
Type "@lua/lay"
Sleep 1.5s
Tab
Sleep 400ms
Enter
Type " pass it."
Enter 2

Type "When it is green, "
Type "/gi"
Sleep 1.5s
Tab
Sleep 400ms
Enter
Type " commit it and open the PR."
Sleep 800ms
Escape
Sleep 4s

# Quit Neovim so demo.sh's cleanup runs.
Hide
Type ":qa!"
Enter
Sleep 500ms
