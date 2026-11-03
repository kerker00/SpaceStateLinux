project('spacestate-desktop',
  version: '0.1.0',
  license: 'MIT',
  meson_version: '>= 1.3',
)

fs = import('fs')
gnome = import('gnome')
i18n = import('i18n')

# What the programs need at build and run time. SwiftPM links them itself; these
# checks only report a missing package here instead of in the middle of the Swift build.
swift = find_program('swift', version: '>= 6.2')
dependency('gio-2.0', version: '>= 2.76')
dependency('gtk4', version: '>= 4.12')

prefix = get_option('prefix')
bindir = prefix / get_option('bindir')
datadir = prefix / get_option('datadir')

swiftpm_args = get_option('swiftpm_args')
release_args = swiftpm_args
if get_option('static_swift_stdlib')
  # Packages then need no Swift installation; GLib and GTK stay dynamic.
  release_args += '--static-swift-stdlib'
endif

# SwiftPM decides itself what to rebuild, so Meson always asks it.
custom_target('programs',
  output: ['spacestate-desktop', 'spacestate-settings'],
  command: [files('build-aux/swift-build.sh'), swift, meson.project_source_root(),
            meson.current_build_dir() / 'swift', meson.current_build_dir(), release_args],
  build_by_default: true,
  build_always_stale: true,
  console: true,
  install: true,
  install_dir: bindir,
)

subdir('po')

install_data('contrib/net.grafixmafia.SpaceState.desktop',
             'contrib/net.grafixmafia.SpaceState.Settings.desktop',
             install_dir: datadir / 'applications')
install_subdir('data/icons/hicolor', install_dir: datadir / 'icons')

# The unit in contrib/ starts ~/.local/bin/spacestate-desktop; the installed one starts this installation.
unit_dir = get_option('systemd_user_unit_dir')
if unit_dir == ''
  # Where distributions put user units; systemd also looks in <datadir>/systemd/user,
  # which covers /usr/local and ~/.local.
  unit_dir = prefix == '/usr' ? '/usr/lib/systemd/user' : datadir / 'systemd/user'
endif
configure_file(
  input: 'contrib/spacestate-desktop.service',
  output: 'spacestate-desktop.service',
  command: ['sed', 's|^ExecStart=.*|ExecStart=' + bindir / 'spacestate-desktop|', '@INPUT@'],
  capture: true,
  install_dir: unit_dir,
)

# Skipped when installing into DESTDIR, where packages run them through their own hooks.
gnome.post_install(gtk_update_icon_cache: true, update_desktop_database: true)

test('swift test', swift,
  args: ['test', '--package-path', meson.project_source_root(),
         '--scratch-path', meson.current_build_dir() / 'swift'] + swiftpm_args,
  timeout: 1200,
  is_parallel: false,
)
desktop_file_validate = find_program('desktop-file-validate', required: false)
if desktop_file_validate.found()
  test('desktop files', desktop_file_validate,
    args: files('contrib/net.grafixmafia.SpaceState.desktop',
                'contrib/net.grafixmafia.SpaceState.Settings.desktop'))
endif

summary({
  'prefix': prefix,
  'programs': bindir,
  'translations': prefix / get_option('localedir'),
  'systemd user unit': unit_dir,
  'static Swift runtime': get_option('static_swift_stdlib'),
})
