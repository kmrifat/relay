# dmgbuild settings for Relay's DMG: the window people see when they open
# it — Relay on the left, Applications on the right, an arrow between
# (design/dmg/background.tiff, drawn by tool/render_dmg_background.swift).
#   dmgbuild -s tool/release/dmg_settings.py -D app=…/Relay.app "Relay" Relay.dmg
import os.path

app = defines.get('app', 'build/macos/Build/Products/Release/Relay.app')  # noqa: F821
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__ if '__file__' in globals() else 'tool/release/x'))))
appname = os.path.basename(app)

format = 'UDZO'
filesystem = 'HFS+'
files = [app]
symlinks = {'Applications': '/Applications'}
hide_extensions = [appname]

background = defines.get('background', os.path.join(root, 'design', 'dmg', 'background.tiff'))  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
# Centres of the two wells in the background art.
icon_locations = {appname: (160, 198), 'Applications': (480, 198)}
