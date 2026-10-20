sources += files(
  'build/child.cc',
  'build/chroot.cc',
  'build/external-derivation-builder.cc',
  'build/hook-instance.cc',
  'build/unix-derivation-builder.cc',
  'pathlocks.cc',
  'user-lock.cc',
)

include_dirs += [ include_directories('build') ]

if (nix_host_system == 'linux' or nix_host_system == 'freebsd')
  sources += files(
    'build/chroot-derivation-builder.cc',
  )
endif

subdir('include/nix/store')
