"copy_to_directory implementation"

load("@bazel_skylib//lib:paths.bzl", skylib_paths = "paths")
load(":copy_common.bzl", _COPY_EXECUTION_REQUIREMENTS = "COPY_EXECUTION_REQUIREMENTS")
load(":paths.bzl", "paths")
load(":directory_path.bzl", "DirectoryPathInfo")

_copy_to_directory_attr = {
    "srcs": attr.label_list(
        allow_files = True,
        doc = """Files and/or directories or targets that provide DirectoryPathInfo to copy
        into the output directory.""",
    ),
    # Cannot declare out as an output here, because there's no API for declaring
    # TreeArtifact outputs.
    "out": attr.string(
        doc = """Path of the output directory, relative to this package.

        If not set, the name of the target is used.""",
    ),
    "root_paths": attr.string_list(
        default = ["."],
        doc = """List of paths that are roots in the output directory.

        "." values indicate the target's package path.

        If a file or directory being copied is in one of the listed paths or one of its subpaths,
        the output directory path is the path relative to the root path instead of the path
        relative to the file's workspace.

        Forward slashes (`/`) should be used as path separators. Partial matches
        on the final path segment of a root path against the corresponding segment
        in the full workspace relative path of a file are not matched.

        If there are multiple root paths that match, the longest match wins.

        Defaults to ["."] so that the output directory path of files in the
        target's package and and sub-packages are relative to the target's package and
        files outside of that retain their full workspace relative paths.""",
    ),
    "include_external_repositories": attr.string_list(
        doc = """List of external repository names to include in the output directory.

        Files from external repositories are not copied into the output directory unless
        the external repository they come from is listed here.

        When copied from an external repository, the file path in the output directory
        defaults to the file's path within the external repository. The external repository
        name is _not_ included in that path.

        For example, the following copies `@external_repo//path/to:file` to
        `path/to/file` within the output directory.

        ```
        copy_to_directory(
            name = "dir",
            include_external_repositories = ["external_repo"],
            srcs = ["@external_repo//path/to:file"],
        )
        ```

        Files from external repositories are subject to `root_paths`, `exclude_prefixes`
        and `replace_prefixes` in the same way as files form the main repository.""",
    ),
    "include_prefixes": attr.string_list(
        doc = """List of path prefixes to include in output directory.

        If empty then all paths are included and subject to `exclude_prefixes` and `replace_prefixes`
        which are matched *after* `include_prefixes`.

        If not empty, a file is only copied to the output directory if 
        the output directory path for a file or directory starts with or is equal to
        a path in the list.

        Forward slashes (`/`) should be used as path separators. The final path segment
        of the key can be a partial match in the corresponding segment of the output
        directory path.

        `include_prefixes` are matched on the output path after `root_paths` are considered.

        `include_prefixes` are matched *before* `exclude_prefixes` and `replace_prefixes` are applied.

        NB: Prefixes that nest into source directories or generated directories (TreeArtifacts) targets
        are not supported since matches are performed in Starlark. To use `include_prefixes` on files
        within directories you can use the `make_directory_paths` helper to specify individual files inside
        directories in `srcs`.""",
    ),
    "exclude_prefixes": attr.string_list(
        doc = """List of path prefixes to exclude from output directory.

        If the output directory path for a file or directory starts with or is equal to
        a path in the list then that file is not copied to the output directory.

        Forward slashes (`/`) should be used as path separators. The final path segment
        of the key can be a partial match in the corresponding segment of the output
        directory path.

        `exclude_prefixes` are matched on the output path after `root_paths` are considered.

        `exclude_prefixes` are matched *after* `include_prefixes` and *before* `replace_prefixes` are applied.
        
        NB: Prefixes that nest into source directories or generated directories (TreeArtifacts) targets
        are not supported since matches are performed in Starlark. To use `exclude_prefixes` on files
        within directories you can use the `make_directory_paths` helper to specify individual files inside
        directories in `srcs`.""",
    ),
    "replace_prefixes": attr.string_dict(
        doc = """Map of paths prefixes to replace in the output directory path when copying files.

        If the output directory path for a file or directory starts with or is equal to
        a key in the dict then the matching portion of the output directory path is
        replaced with the dict value for that key.

        Forward slashes (`/`) should be used as path separators. The final path segment
        of the key can be a partial match in the corresponding segment of the output
        directory path.

        `replace_prefixes` are matched on the output path after `root_paths` are considered.

        `replace_prefixes` are matched *after* `include_prefixes` and `exclude_prefixes` are applied.

        If there are multiple keys that match, the longest match wins.

        NB: Prefixes that nest into source directories or generated directories (TreeArtifacts) targets
        are not supported since matches are performed in Starlark. To use `replace_prefixes` on files
        within directories you can use the `make_directory_paths` helper to specify individual files inside
        directories in `srcs`.""",
    ),
    "allow_overwrites": attr.bool(
        doc = """If True, allow files to be overwritten if the same output file is copied to twice.

        If set, then the order of srcs matters as the last copy of a particular file will win.

        This setting has no effect on Windows where overwrites are always allowed.""",
    ),
    "_windows_constraint": attr.label(default = "@platforms//os:windows"),
}

def _first_match(subject, tests, allow_partial = False):
    for test in tests:
        starts_with_test = test if allow_partial or test.endswith("/") else test + "/"
        if subject == test or subject.startswith(starts_with_test):
            return test
    return None

def _longest_match(subject, tests, allow_partial = False):
    match = None
    high_score = 0
    for test in tests:
        starts_with_test = test if allow_partial or test.endswith("/") else test + "/"
        if subject == test or subject.startswith(starts_with_test):
            score = len(test)
            if score > high_score:
                match = test
                high_score = score
    return match

# src can either be a File or a target with a DirectoryPathInfo
def _copy_paths(
        src,
        root_paths,
        include_external_repositories,
        include_prefixes,
        exclude_prefixes,
        replace_prefixes):
    if type(src) == "File":
        src_file = src
        src_path = src_file.path
        output_path = paths.to_workspace_path(src_file)
    elif DirectoryPathInfo in src:
        src_file = src[DirectoryPathInfo].directory
        src_path = "/".join([src_file.path, src[DirectoryPathInfo].path])
        output_path = "/".join([paths.to_workspace_path(src_file), src[DirectoryPathInfo].path])
    else:
        fail("Unsupported type")

    # if the file is from an external repository check if that repository should
    # be included in the output directory
    if src_file.owner and src_file.owner.workspace_name and not src_file.owner.workspace_name in include_external_repositories:
        return None, None, None

    # strip root paths
    root_path = _longest_match(output_path, root_paths)
    if root_path:
        strip_depth = len(root_path.split("/"))
        output_path = "/".join(output_path.split("/")[strip_depth:])

    if include_prefixes:
        # check if this file matches an include_prefix if they are specified
        match = _first_match(output_path, include_prefixes, True)
        if not match:
            # file is excluded as it does not match any specified include_prefix
            return None, None, None

    # check if this file matches an exclude_prefix
    match = _first_match(output_path, exclude_prefixes, True)
    if match:
        # file is excluded due to match in exclude_prefix
        return None, None, None

    # apply a replacement if one is found
    match = _longest_match(output_path, replace_prefixes.keys(), True)
    if match:
        output_path = replace_prefixes[match] + output_path[len(match):]

    return src_path, output_path, src_file

def _copy_to_dir_bash(ctx, copy_paths, dst_dir, allow_overwrites):
    cmds = [
        "set -o errexit -o nounset -o pipefail",
        "OUT_CAPTURE=$(mktemp)",
        """_exit() {
    EXIT_CODE=$?;
    if [ "$EXIT_CODE" != 0 ]; then
        cat "$OUT_CAPTURE"
    fi
    exit $EXIT_CODE
}""",
        "trap _exit EXIT",
        "mkdir -p \"%s\"" % dst_dir.path,
    ]

    inputs = []

    for src_path, dst_path, src_file in copy_paths:
        inputs.append(src_file)

        maybe_force = "-f " if allow_overwrites else "-n "
        maybe_chmod_file = """if [ -e "{dst}" ]; then
    chmod a+w "{dst}"
fi
""" if allow_overwrites else ""
        maybe_chmod_dir = """if [ -e "{dst}" ]; then
    chmod -R a+w "{dst}"
fi
""" if allow_overwrites else ""

        cmds.append("""
if [[ ! -e "{src}" ]]; then echo "file '{src}' does not exist"; exit 1; fi
if [[ -f "{src}" ]]; then
    mkdir -p "{dst_dir}"
    {maybe_chmod_file}cp -v {maybe_force}"{src}" "{dst}" >> "$OUT_CAPTURE" 2>>"$OUT_CAPTURE"
else
    if [[ -d "{dst}" ]]; then
        # When running outside the sandbox, then an earlier copy will create the dst folder
        # with nested read-only folders, so our copy operation will fail to write there.
        # Make sure the output folders are writeable.
        find "{dst}" -type d -print0 | xargs -0 chmod a+w
    fi
    mkdir -p "{dst}"
    {maybe_chmod_dir}cp -v -R {maybe_force}"{src}/." "{dst}" >> "$OUT_CAPTURE" 2>>"$OUT_CAPTURE"
fi
""".format(
            src = src_path,
            dst_dir = skylib_paths.dirname(dst_path),
            dst = dst_path,
            maybe_force = maybe_force,
            maybe_chmod_file = maybe_chmod_file,
            maybe_chmod_dir = maybe_chmod_dir,
        ))

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [dst_dir],
        command = "\n".join(cmds),
        mnemonic = "CopyToDirectory",
        progress_message = "Copying files to directory",
        use_default_shell_env = True,
        execution_requirements = _COPY_EXECUTION_REQUIREMENTS,
    )

def _copy_to_dir_cmd(ctx, copy_paths, dst_dir):
    # Most Windows binaries built with MSVC use a certain argument quoting
    # scheme. Bazel uses that scheme too to quote arguments. However,
    # cmd.exe uses different semantics, so Bazel's quoting is wrong here.
    # To fix that we write the command to a .bat file so no command line
    # quoting or escaping is required.
    # Based on skylib copy_file:
    # https://github.com/bazelbuild/bazel-skylib/blob/main/rules/private/copy_file_private.bzl#L28.
    bat = ctx.actions.declare_file(ctx.label.name + "-cmd.bat")

    # NB: mkdir will create all subdirectories; it will exit 1
    # print an error to stderr if the directory already exists so
    # we supress both its stdout & stderr output
    cmds = ["""
@rem @generated by @aspect_bazel_lib//lib/private:copy_to_directory.bzl
@echo off
mkdir "%s" >NUL 2>NUL
""" % dst_dir.path.replace("/", "\\")]

    inputs = []

    for src_path, dst_path, src_file in copy_paths:
        inputs.append(src_file)

        # copy & xcopy flags are documented at
        # https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/copy
        # https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy
        cmds.append("""
if not exist "{src}" (
    echo file "{src}" does not exist
    exit /b 1
)
if exist "{src}\\*" (
    mkdir "{dst}" >NUL 2>NUL
    robocopy "{src}" "{dst}" /E >NUL
) else (
    mkdir "{dst_dir}" >NUL 2>NUL
    copy /Y "{src}" "{dst}" >NUL
)
""".format(
            src = src_path.replace("/", "\\"),
            dst_dir = skylib_paths.dirname(dst_path).replace("/", "\\"),
            dst = dst_path.replace("/", "\\"),
        ))

    # robocopy return non-zero exit codes on success so we must exit 0 when we are done
    cmds.append("exit 0")

    ctx.actions.write(
        output = bat,
        # Do not use lib/shell.bzl's shell.quote() method, because that uses
        # Bash quoting syntax, which is different from cmd.exe's syntax.
        content = "\n".join(cmds),
        is_executable = True,
    )

    ctx.actions.run(
        inputs = inputs,
        tools = [bat],
        outputs = [dst_dir],
        executable = "cmd.exe",
        arguments = ["/C", bat.path.replace("/", "\\")],
        mnemonic = "CopyToDirectory",
        progress_message = "Copying files to directory",
        use_default_shell_env = True,
    )

def _copy_to_directory_impl(ctx):
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])

    if not ctx.attr.srcs:
        msg = "srcs must not be empty in copy_to_directory %s" % ctx.label
        fail(msg)

    dst = ctx.actions.declare_directory(ctx.attr.out if ctx.attr.out else ctx.attr.name)

    copy_to_directory_action(
        ctx,
        srcs = ctx.attr.srcs,
        dst = dst,
        root_paths = ctx.attr.root_paths,
        include_external_repositories = ctx.attr.include_external_repositories,
        include_prefixes = ctx.attr.include_prefixes,
        exclude_prefixes = ctx.attr.exclude_prefixes,
        replace_prefixes = ctx.attr.replace_prefixes,
        allow_overwrites = ctx.attr.allow_overwrites,
        is_windows = is_windows,
    )

    return [
        DefaultInfo(
            files = depset([dst]),
            runfiles = ctx.runfiles([dst]),
        ),
    ]

def copy_to_directory_action(
        ctx,
        srcs,
        dst,
        additional_files = [],
        root_paths = ["."],
        include_external_repositories = [],
        include_prefixes = [],
        exclude_prefixes = [],
        replace_prefixes = {},
        allow_overwrites = False,
        is_windows = False):
    """Helper function to copy files to a directory.

    This helper is used by copy_to_directory. It is exposed as a public API so it can be used within
    other rule implementations where additional_files can also be passed in.

    Args:
        ctx: The rule context.

        srcs: Files and/or directories or targets that provide DirectoryPathInfo to copy into the output directory.

        dst: The directory to copy to. Must be a TreeArtifact.

        additional_files: Additional files to copy that are not in the DefaultInfo or DirectoryPathInfo of srcs

        root_paths: List of paths that are roots in the output directory.

            See copy_to_directory rule documentation for more details.

        include_external_repositories: List of external repository names to include in the output directory.

            See copy_to_directory rule documentation for more details.

        include_prefixes: List of path prefixes to include in output directory.

            See copy_to_directory rule documentation for more details.

        exclude_prefixes: List of path prefixes to exclude from output directory.

            See copy_to_directory rule documentation for more details.

        replace_prefixes: Map of paths prefixes to replace in the output directory path when copying files.

            See copy_to_directory rule documentation for more details.

        allow_overwrites: If True, allow files to be overwritten if the same output file is copied to twice.

            See copy_to_directory rule documentation for more details.

        is_windows: If true, an cmd.exe action is created so there is no bash dependency.
    """
    if not srcs:
        fail("srcs must not be empty")

    # Replace "." root paths with the package name of the target
    root_paths = [p if p != "." else ctx.label.package for p in root_paths]

    # Gather a list of src_path, dst_path pairs
    copy_paths = []
    for src in srcs:
        if DirectoryPathInfo in src:
            src_path, output_path, src_file = _copy_paths(
                src = src,
                root_paths = root_paths,
                include_external_repositories = include_external_repositories,
                include_prefixes = include_prefixes,
                exclude_prefixes = exclude_prefixes,
                replace_prefixes = replace_prefixes,
            )
            if src_path != None:
                dst_path = skylib_paths.normalize("/".join([dst.path, output_path]))
                copy_paths.append((src_path, dst_path, src_file))
        if DefaultInfo in src:
            for src_file in src[DefaultInfo].files.to_list():
                src_path, output_path, src_file = _copy_paths(
                    src = src_file,
                    root_paths = root_paths,
                    include_external_repositories = include_external_repositories,
                    include_prefixes = include_prefixes,
                    exclude_prefixes = exclude_prefixes,
                    replace_prefixes = replace_prefixes,
                )
                if src_path != None:
                    dst_path = skylib_paths.normalize("/".join([dst.path, output_path]))
                    copy_paths.append((src_path, dst_path, src_file))
    for additional_file in additional_files:
        src_path, output_path, src_file = _copy_paths(
            src = additional_file,
            root_paths = root_paths,
            include_external_repositories = include_external_repositories,
            include_prefixes = include_prefixes,
            exclude_prefixes = exclude_prefixes,
            replace_prefixes = replace_prefixes,
        )
        if src_path != None:
            dst_path = skylib_paths.normalize("/".join([dst.path, output_path]))
            copy_paths.append((src_path, dst_path, src_file))

    if is_windows:
        _copy_to_dir_cmd(ctx, copy_paths, dst)
    else:
        _copy_to_dir_bash(ctx, copy_paths, dst, allow_overwrites)

copy_to_directory_lib = struct(
    attrs = _copy_to_directory_attr,
    impl = _copy_to_directory_impl,
    provides = [DefaultInfo],
)
