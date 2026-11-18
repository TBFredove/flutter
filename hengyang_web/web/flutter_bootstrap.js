{{flutter_js}}
{{flutter_build_config}}

// Legacy Flutter workers intercept bare asset URLs and ?v= URLs.
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath) build.mainJsPath += '?cache-migration=1';
}

_flutter.loader.load();
