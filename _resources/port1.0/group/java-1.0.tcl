# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4
#
# This PortGroup accommodates Java projects by setting the JAVA_HOME environment
# variable appropriately for the configure, build, and destroot phases.
#
# Usage:
#
# PortGroup     java 1.0
#
# java.version  1.8
#
# The java.version option allows one to optionally specify a required Java
# version. The syntax is the same as that accepted by /usr/libexec/java_home:
#
# - Java 8 and earlier are "1.8", etc.
# - Java 9 and later are "9", etc.
# - "+" and "*" wilcards are supported
#
# If the required Java cannot be found, an error will be thrown at pre-fetch.

options java.version java.home java.fallback

default java.version  {}
default java.home     {}
default java.fallback {}

# allow PortGroup to be used inside a variant (e.g. octave)
global java_version_not_found
set java_version_not_found no

pre-fetch {
    if { ${java_version_not_found} } {
        # Check again, incase java became available, .e.g openjdk installed as a dependency
        java_set_env
        # If still not present, error out
        if { ${java_version_not_found} } {
            global os.platform os.major
            if {${os.platform} eq "darwin" && ${os.major} >= 20} {
                # The following check is broken on macOS 11 Big Sur so we
                # temporarily give up on ensuring an exact Java version. See
                # https://trac.macports.org/ticket/61445
                ui_warn "Failed to confirm that required Java was installed; see https://trac.macports.org/ticket/61445"
            } else {
                ui_error "${name} requires Java ${java.version} but no such installation could be found."
                return -code error "missing required Java version"
            }
        }
    }
}

# Search for a good value for JAVA_HOME
proc find_java_home {} {
    set home_value ""

    # Default setting to found, until proved otherwise below
    global java_version_not_found
    set java_version_not_found no

    global java.version java.fallback
    if { ${java.version} ne "" } {
        global os.platform os.major

        set big_sur_workaround [expr {${os.platform} eq "darwin" && ${os.major} == 20}]
        if { ${big_sur_workaround} && [catch {set val [get_jvm_bigsur ${java.version}] } ]
        || !${big_sur_workaround} && [catch {set val [exec "/usr/libexec/java_home" "-f" "-v" ${java.version}] } ] } {
            # Don't return an error because that would prevent the port from
            # even being indexed when the required Java is missing. Instead, set
            # a flag to be checked at pre-fetch.
            set java_version_not_found yes
        } else {
            set home_value $val
            ui_debug "Discovered JAVA_HOME via /usr/libexec/java_home \[-f -v|-V\]: $home_value"
        }
    }

    # Default to any valid value that made it through the environment
    if { ![file isdirectory $home_value] && \
             [info exists ::env(JAVA_HOME)] } {
        set val $::env(JAVA_HOME)
        if { [file isdirectory $val] } {
            set home_value $val
            ui_debug "Discovered JAVA_HOME via env: $home_value"
        }
    }

    # First, ask the system where java home is
    if { ![file isdirectory $home_value] && ![catch {set val [exec "/usr/libexec/java_home"]}] } {
        set home_value $val
        ui_debug "Discovered JAVA_HOME via /usr/libexec/java_home: $home_value"
    }

    # Fall back to more conventional way to find java home
    if { ![file isdirectory $home_value] } {
        foreach loc { "/System/Library/Frameworks/JavaVM.framework/Home" } {
            if { [file isdirectory $loc] } {
                set home_value $loc
                ui_debug "Discovered JAVA_HOME via search path: $home_value"
                break
            }
        }
    }

    # Warn user if we couldn't find a likely JAVA_HOME
    if { ![file isdirectory $home_value]} {
        ui_debug "No value for java JAVA_HOME was automatically discovered"
    }

    # Add dependency if required
    if { ${java_version_not_found} && ${java.fallback} ne "" } {
        ui_debug "Adding dependency on JDK fallback ${java.fallback}"
        depends_lib-append port:${java.fallback}
    }

    return $home_value
}

proc java_set_env {} {
    # Set the best value we can find for JAVA_HOME
    set java_home [find_java_home]
    configure.env-append   JAVA_HOME=${java_home}
    build.env-append       JAVA_HOME=${java_home}
    destroot.env-append    JAVA_HOME=${java_home}
    java.home ${java_home}
}

port::register_callback java_set_env

proc get_jvm_bigsur { version_requested } {
    # Normalize version numbers 1.x -> x
    set version_requested [regsub {^1\.} $version_requested ""]
    # Sort the JVMs we found on the system descending
    set versions_found [sort_dict [find_jvm_versions]]
    ui_debug "Big Sur Workaround - Detected JVMs: $versions_found"
    # Match the systems JVMs with the one requested by MacPorts
    # Higher JVM Versions win
    return [match_jvm_version $version_requested $versions_found]
}

# Find JVM versions by using /usr/libexec/java_home -V (not -v!)
# Returns a dict of unique(!) major versions [major_version path]
proc find_jvm_versions {} {
    if {[catch {exec /usr/libexec/java_home -V} result options]} {
        # Extract JVM versions and corresponding JAVA_HOMEs
        set vm_versions [regexp -all -inline -- { +(\d+(?:\.\d+)+)[^/]+(\/[^\0\n]+)} $result]
        # %3=0 -> Regex match, ignored.
        # %3=1 -> Version
        # %3=2 -> JAVA_HOME.
        for {set idx 0} {$idx < [llength $vm_versions]} {incr idx 3} {
            set vers [lindex $vm_versions $idx+1]
            # Normalize version 1.x -> x
            set vers [regsub {^1\.} $vers ""]
            # Extract major version
            set vers [regsub {(\.\d+)+} $vers ""]
            set path [lindex $vm_versions $idx+2]
            dict append version_path_dict $vers $path
        }
    } else {
        set details [dict get $options -errorcode]
        ui_debug "Error executing /usr/libexec/java_home -V"
    }
    set version_path_dict
}

# Match a normalized major version string like 7, 8*, 9+
proc match_jvm_version { version_requested versions_found } {
    if {[string first "+" $version_requested] != -1} {
        set version_requested [regsub {\+} $version_requested ""]
        match_less_equal $version_requested $versions_found
    } else {
        set version_requested [regsub {\*} $version_requested ""]
        match_equal $version_requested $versions_found
    }
}

proc match_equal { version version_list } {
    foreach vl_item [dict keys $version_list] {
        if {$version == $vl_item} {
            set java_home [dict get $version_list $vl_item]
            return $java_home
        }
    }
    return -code error
}

proc match_less_equal { version version_list } {
    foreach vl_item [dict keys $version_list] {
        if {$version <= $vl_item} {
            set java_home [dict get $version_list $vl_item]
            return $java_home
        }
    }
    return -code error
}

proc sort_dict { unsorted_dict } {
    set dkeys [dict keys $unsorted_dict]
    set dkeys_sorted [lsort -decreasing $dkeys]

    foreach place $dkeys_sorted {
        set jvm_path [dict get $unsorted_dict $place]
        dict append version_path_dict $place $jvm_path
    }
    return $version_path_dict
}
