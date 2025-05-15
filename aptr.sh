#!/bin/bash

# aptr - APT Rolling Package Manager
# Version: 1.0.0
# A tool for managing mixed source Debian systems with both stable and unstable (Sid) packages
# Author: domwxyz
# License: GPLv3

set -e

# Configuration constants
readonly PROGRAM_NAME="aptr"
readonly VERSION="1.0.0"
readonly UNSTABLE_SOURCES="/etc/apt/sources.list.d/aptr-unstable.list"
readonly PREFERENCES_FILE="/etc/apt/preferences.d/aptr-preferences"
readonly ROLLING_PACKAGES_FILE="/var/lib/aptr/rolling-packages"
readonly ROLLING_DEPS_FILE="/var/lib/aptr/rolling-dependencies"
readonly CONFIG_DIR="/var/lib/aptr"
readonly LOCK_FILE="/var/run/aptr.lock"
readonly LOG_FILE="/var/log/aptr.log"

# Default configuration
VERBOSE=false
DRY_RUN=false
FORCE=false
YES=false
STABLE=false

# Colors for output (only if terminal supports it)
if [[ -t 1 ]] && command -v tput &> /dev/null; then
    readonly RED=$(tput setaf 1)
    readonly GREEN=$(tput setaf 2)
    readonly YELLOW=$(tput setaf 3)
    readonly BLUE=$(tput setaf 4)
    readonly BOLD=$(tput bold)
    readonly NC=$(tput sgr0)
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly BOLD=""
    readonly NC=""
fi

# Logging functions
log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log_to_file "INFO: $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log_to_file "SUCCESS: $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log_to_file "WARNING: $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    log_to_file "ERROR: $1"
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
        log_to_file "VERBOSE: $1"
    fi
}

# Utility functions
cleanup() {
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
}

# Set up signal handlers
trap cleanup EXIT INT TERM

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges. Please run with sudo."
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Another instance of $PROGRAM_NAME is already running (PID: $pid)"
            exit 1
        else
            log_warning "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi

    (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null || {
        log_error "Failed to create lock file (another instance started concurrently)"
        exit 1
    }
}

check_apt_lock() {
    local lock_files=(
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
    )
    
    for lock_file in "${lock_files[@]}"; do
        if fuser "$lock_file" >/dev/null 2>&1; then
            log_error "APT is locked by another process (${lock_file})"
            log_info "Wait for other package operations to complete, or run 'sudo killall apt apt-get'"
            return 1
        fi
    done
    return 0
}

validate_package_name() {
    local package="$1"
    
    # Only allow standard package name characters
    if [[ ! "$package" =~ ^[a-zA-Z0-9][a-zA-Z0-9+._-]*$ ]]; then
        log_error "Invalid package name: $package"
        return 1
    fi
    
    # Prevent excessively long names (common in injection attacks)
    if [[ ${#package} -gt 80 ]]; then
        log_error "Package name too long: $package"
        return 1
    fi
    
    # Block dangerous characters/sequences
    if [[ "$package" == *".."* ]] || [[ "$package" == *"/"* ]] || [[ "$package" == *";"* ]] || [[ "$package" == *"|"* ]]; then
        log_error "Package name contains invalid characters: $package"
        return 1
    fi

    # Additional checks for problematic patterns
    if [[ "$package" =~ (^-|--|-$|\.\.|^\.|\.$) ]]; then
        log_error "Package name contains invalid patterns: $package"
        return 1
    fi
    
    return 0
}

package_exists() {
    local package="$1"
    local source="${2:-}"
    
    if [[ -n "$source" ]]; then
        apt-cache policy "$package" 2>/dev/null | grep -q "Candidate.*$source" || return 1
    else
        apt-cache show "$package" &>/dev/null || return 1
    fi
    return 0
}

is_virtual_package() {
    local package="$1"
    
    # Virtual packages show "Package: <name>" followed by "Reverse Depends:" but no "Description:"
    if apt-cache show "$package" 2>/dev/null | grep -q "^Package: $package$"; then
        # Real package found
        return 1
    else
        # Check if it's provided by other packages (virtual)
        apt-cache search --names-only "^$package$" 2>/dev/null | grep -q "^$package " && return 1
        apt-cache showpkg "$package" 2>/dev/null | grep -q "^Reverse Provides:" && return 0
        return 1
    fi
}

confirm_action() {
    local message="$1"
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    
    echo -n -e "${YELLOW}$message${NC} [y/N]: "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Configuration management
setup_config() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        if ! mkdir -p "$CONFIG_DIR"; then
            log_error "Failed to create configuration directory"
            return 1
        fi
        log_verbose "Created configuration directory: $CONFIG_DIR"
    fi
    
    # Create all necessary files
    for file in "$ROLLING_PACKAGES_FILE" "$ROLLING_DEPS_FILE"; do
        if [[ ! -f "$file" ]]; then
            if ! touch "$file"; then
                log_error "Failed to create $(basename "$file")"
                return 1
            fi
            chmod 644 "$file"
            log_verbose "Created $(basename "$file")"
        fi
    done
    
    # Ensure log directory exists
    log_dir=$(dirname "$LOG_FILE")
    if ! mkdir -p "$log_dir"; then
        echo "Warning: Failed to create log directory $log_dir" >&2
        echo "Continuing without file logging..." >&2
        LOG_FILE="/dev/null"
    fi
    if [[ "$LOG_FILE" != "/dev/null" ]]; then
        if ! touch "$LOG_FILE" 2>/dev/null; then
            echo "Warning: Cannot create log file $LOG_FILE" >&2
            LOG_FILE="/dev/null"
        else
            chmod 644 "$LOG_FILE"
        fi
    fi
}

detect_debian_codename() {
    local codename=""
    
    # Try multiple sources for codename detection
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/etc/os-release
        codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    # Fallback to lsb_release
    if [[ -z "$codename" ]] && command -v lsb_release &>/dev/null; then
        codename=$(lsb_release -cs 2>/dev/null || true)
    fi
    
    # Fallback to debian_version
    if [[ -z "$codename" ]] && [[ -f /etc/debian_version ]]; then
        local version=$(cat /etc/debian_version)
        case "$version" in
            12*) codename="bookworm" ;;
            11*) codename="bullseye" ;;
            10*) codename="buster" ;;
            9*) codename="stretch" ;;
            8*) codename="jessie" ;;
            *) codename="bookworm" ;;  # Default for unknown versions
        esac
    fi
    
    # Final fallback
    echo "${codename:-bookworm}"
}

setup_unstable_sources() {
    if [[ -f "$UNSTABLE_SOURCES" ]]; then
        log_verbose "Unstable sources already configured"
        return 0
    fi
    
    log_info "Setting up unstable sources..."
    
    # Detect current mirror and architecture
    local current_sources="/etc/apt/sources.list"
    local debian_mirror=""

    # Detect Debian version to determine appropriate components
    local codename=$(detect_debian_codename)
    local components="main contrib non-free"
    
    # Add non-free-firmware for bookworm (Debian 12) and newer
    case "$codename" in
        bookworm|trixie|forky|sid)
            components="main contrib non-free non-free-firmware"
            log_verbose "Using components with non-free-firmware for $codename"
            ;;
        *)
            log_verbose "Using traditional components for $codename (no non-free-firmware)"
            ;;
    esac
    
    # Try to detect mirror from existing sources
    if [[ -f "$current_sources" ]]; then
        debian_mirror=$(grep -E "^deb\s+" "$current_sources" | head -1 | awk '{print $2}')
    fi
    
    # Fallback to default mirrors
    if [[ -z "$debian_mirror" ]] || [[ "$debian_mirror" == "cdrom:"* ]]; then
        debian_mirror="https://deb.debian.org/debian"
        log_warning "Could not detect mirror, using default: $debian_mirror"
    fi
    
    # Create unstable sources
    if ! cat > "$UNSTABLE_SOURCES" << EOF
# APT Rolling Package Manager - Unstable Sources
# Auto-generated by $PROGRAM_NAME v$VERSION
# Do not edit manually - managed by $PROGRAM_NAME

deb $debian_mirror unstable $components
deb-src $debian_mirror unstable $components
EOF
    then
        log_error "Failed to create unstable sources file: $UNSTABLE_SOURCES"
        return 1
    fi
    
    if ! chmod 644 "$UNSTABLE_SOURCES"; then
        log_error "Failed to set permissions on unstable sources file"
        return 1
    fi
    log_success "Created unstable sources file"
}

setup_preferences() {
    if [[ -f "$PREFERENCES_FILE" ]]; then
        log_verbose "APT preferences already configured"
        return 0
    fi
    
    log_info "Setting up APT preferences for intelligent pinning..."
    
    local stable_codename=$(detect_debian_codename)
    
    cat > "$PREFERENCES_FILE" << EOF
# APT Rolling Package Manager - Preferences
# Auto-generated by $PROGRAM_NAME v$VERSION
# Do not edit manually - managed by $PROGRAM_NAME

# Default: strongly prefer stable packages
Package: *
Pin: release a=$stable_codename
Pin-Priority: 990

# Secondary preference for stable
Package: *
Pin: release a=stable
Pin-Priority: 900

# Unstable packages have very low priority by default
Package: *
Pin: release a=unstable
Pin-Priority: 200

# Prevent accidental installation from experimental
Package: *
Pin: release a=experimental
Pin-Priority: 50
EOF
    
    chmod 644 "$PREFERENCES_FILE"
    log_success "Created APT preferences file with intelligent pinning"
}

# Core functionality
init_system() {
    log_info "Initializing $PROGRAM_NAME v$VERSION..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would initialize system configuration"
        return 0
    fi
    
    setup_config
    setup_unstable_sources
    setup_preferences
    
    log_info "Updating package lists..."
    check_apt_lock || return 1
    if ! apt-get update; then
        log_error "Failed to update package lists"
        return 1
    fi
    
    log_success "System successfully initialized for mixed package management"
    log_info "You can now use '$PROGRAM_NAME install <package>' to install from unstable"
}

add_to_rolling_list() {
    local package="$1"
    local parent="${2:-}"  # Optional parent package
    
    if ! grep -q "^$package$" "$ROLLING_PACKAGES_FILE" 2>/dev/null; then
        if ! echo "$package" >> "$ROLLING_PACKAGES_FILE"; then
            log_error "Failed to add $package to rolling packages file"
            return 1
        fi
        
        # Track dependency relationship if this is a dependency
        if [[ -n "$parent" ]]; then
            if ! echo "$package:$parent" >> "$ROLLING_DEPS_FILE"; then
                log_error "Failed to track dependency for $package"
                return 1
            fi
        fi
        
        log_verbose "Added $package to rolling packages list"
        return 0
    fi
    return 1
}

remove_from_rolling_list() {
    local package="$1"
    
    if [[ -f "$ROLLING_PACKAGES_FILE" ]]; then
        sed -i "/^${package}$/d" "$ROLLING_PACKAGES_FILE"
        log_verbose "Removed $package from rolling packages list"
    fi
}

create_package_preference() {
    local package="$1"
    local priority="${2:-990}"
    
    # Validate package name first
    validate_package_name "$package" || return 1
    
    # Sanitize package name for filename (remove any remaining unsafe chars)
    local safe_package="${package//[^a-zA-Z0-9+._-]/}"
    local package_pref_file="/etc/apt/preferences.d/aptr-${safe_package}"
    
    # Double-check the final path is safe
    if [[ "$package_pref_file" != "/etc/apt/preferences.d/aptr-"* ]]; then
        log_error "Invalid preference file path generated"
        return 1
    fi
    
    if ! cat > "$package_pref_file" << EOF
# APT Rolling Package: $package
# Managed by $PROGRAM_NAME - do not edit manually

Package: $package
Pin: release a=unstable
Pin-Priority: $priority

# Also pin related packages with same name prefix
Package: ${package}*
Pin: release a=unstable
Pin-Priority: $priority
EOF
    then
        log_error "Failed to create preference file for $package"
        return 1
    fi
    

    if ! chmod 644 "$package_pref_file"; then
        log_error "Failed to set permissions on preference file for $package"
        return 1
    fi
    log_verbose "Created preference file for $package"
}

remove_package_preference() {
    local package="$1"
    
    # Validate and sanitize
    validate_package_name "$package" || return 1
    local safe_package="${package//[^a-zA-Z0-9+._-]/}"
    local package_pref_file="/etc/apt/preferences.d/aptr-${safe_package}"
    
    # Verify path safety
    if [[ "$package_pref_file" != "/etc/apt/preferences.d/aptr-"* ]]; then
        log_error "Invalid preference file path"
        return 1
    fi
    
    if [[ -f "$package_pref_file" ]]; then
        rm "$package_pref_file"
        log_verbose "Removed preference file for $package"
    fi
}

pin_dependencies() {
    local pkg=$1
    local deps
    deps=$(apt-cache depends "$pkg" | awk '/^\s*Depends:/ {print $2}' | grep -v "^<.*>$")

    for dep in $deps; do
        # Skip if already tracked as a main rolling package
        if grep -qx "$dep" "$ROLLING_PACKAGES_FILE"; then
            log_verbose "Dependency $dep already tracked as rolling package"
            continue
        fi

        if is_virtual_package "$dep"; then
            log_verbose "Skipping virtual package dependency: $dep"
            continue
        fi
        
        # Check if it's already a dependency of another package
        if ! grep -q "^$dep:" "$ROLLING_DEPS_FILE" 2>/dev/null; then
            log_verbose "Pinning dependency $dep for $pkg"
            create_package_preference "$dep" 500
            add_to_rolling_list "$dep" "$pkg"
        else
            log_verbose "Dependency $dep already pinned for another package"
        fi
    done
}

install_package() {
    local package="$1"
    local from_unstable="${2:-auto}"
    
    # Determine install source based on flags
    if [[ "$STABLE" == true ]]; then
        from_unstable=false
    elif [[ "$from_unstable" == "auto" ]]; then
        from_unstable=true  # Default behavior is unstable
    fi
    
    validate_package_name "$package" || return 1
    
    if [[ "$from_unstable" == true ]]; then
        log_info "Installing $package from unstable..."
        
        # Check if package exists in unstable
        if ! package_exists "$package"; then
            log_warning "Package '$package' not found. Updating package lists..."
            check_apt_lock || return 1
            apt-get update
            if ! package_exists "$package"; then
                log_error "Package '$package' not found in any repository"
                return 1
            fi
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would install $package from unstable"
            return 0
        fi
        
        # Add to rolling list and create preference
        add_to_rolling_list "$package"
        create_package_preference "$package"
        pin_dependencies "$package"
        
        # Build apt command with optional -y flag
        local apt_cmd="apt-get install -t unstable"
        if [[ "$YES" == true ]]; then
            apt_cmd="$apt_cmd -y"
        fi
        
        # Install with specific target
        check_apt_lock || return 1
        if DEBIAN_FRONTEND=noninteractive $apt_cmd "$package"; then
            log_success "Successfully installed $package from unstable"
        else
            log_error "Failed to install $package from unstable"
            remove_from_rolling_list "$package"
            remove_package_preference "$package"
            return 1
        fi
    else
        log_info "Installing $package from stable..."
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would install $package from stable"
            return 0
        fi
        
        # Build apt command with optional -y flag
        local apt_cmd="apt-get install"
        if [[ "$YES" == true ]]; then
            apt_cmd="$apt_cmd -y"
        fi
        
        check_apt_lock || return 1
        if DEBIAN_FRONTEND=noninteractive $apt_cmd "$package"; then
            log_success "Successfully installed $package from stable"
        else
            log_error "Failed to install $package from stable"
            return 1
        fi
    fi
}

list_rolling_packages() {
    if [[ ! -f "$ROLLING_PACKAGES_FILE" || ! -s "$ROLLING_PACKAGES_FILE" ]]; then
        log_info "No rolling packages configured"
        return 0
    fi
    
    echo -e "${BOLD}Rolling Packages:${NC}"
    echo -e "${BOLD}================${NC}"
    
    local count=0
    local main_packages=0
    local dep_packages=0
    
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        ((count++))
        
        # Check if this is a dependency
        local is_dependency=""
        local parent_packages=""
        if [[ -f "$ROLLING_DEPS_FILE" ]]; then
            parent_packages=$(grep "^$package:" "$ROLLING_DEPS_FILE" | cut -d: -f2 | tr '\n' ' ')
            if [[ -n "$parent_packages" ]]; then
                is_dependency=" (dep of: ${parent_packages% })"
                ((dep_packages++))
            else
                ((main_packages++))
            fi
        else
            ((main_packages++))
        fi
        
        # Get current version info
        local version=""
        if command -v dpkg-query &>/dev/null; then
            version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || echo "Not installed")
        fi
        
        printf "%-25s %-35s %s\n" "$package" "${version:0:35}" "$is_dependency"
        
        if [[ "$VERBOSE" == true ]]; then
            # Show available version
            local available=$(apt-cache policy "$package" 2>/dev/null | grep -A1 "unstable" | tail -1 | awk '{print $1}' || echo "Unknown")
            [[ -n "$available" && "$available" != "Unknown" ]] && \
                printf "%-25s └─ Available: %s\n" "" "$available"
        fi
    done < "$ROLLING_PACKAGES_FILE"
    
    echo
    log_info "Total: $count packages ($main_packages main, $dep_packages dependencies)"
}

upgrade_rolling_packages() {
    if [[ ! -f "$ROLLING_PACKAGES_FILE" || ! -s "$ROLLING_PACKAGES_FILE" ]]; then
        log_info "No rolling packages to upgrade"
        return 0
    fi
    
    log_info "Updating package lists..."
    check_apt_lock || return 1
    apt-get update
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would upgrade the following rolling packages:"
        cat "$ROLLING_PACKAGES_FILE"
        return 0
    fi
    
    log_info "Upgrading rolling packages..."
    local failed_packages=()
    local upgraded_count=0
    
    # Build apt command with optional -y flag
    local apt_cmd="apt-get install -t unstable"
    if [[ "$YES" == true ]]; then
        apt_cmd="$apt_cmd -y"
    fi
    
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        
        log_verbose "Checking $package for updates..."
        check_apt_lock || return 1
        if DEBIAN_FRONTEND=noninteractive $apt_cmd "$package"; then
            ((upgraded_count++))
            log_success "Upgraded $package"
        else
            failed_packages+=("$package")
            log_warning "Failed to upgrade $package"
        fi
    done < "$ROLLING_PACKAGES_FILE"
    
    if [[ ${#failed_packages[@]} -eq 0 ]]; then
        log_success "All $upgraded_count rolling packages upgraded successfully"
    else
        log_warning "Upgraded $upgraded_count packages, but ${#failed_packages[@]} failed:"
        printf '  - %s\n' "${failed_packages[@]}"
    fi
}

upgrade_system() {
    log_info "Performing full system upgrade (stable + rolling packages)..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would run full system upgrade"
        log_info "[DRY RUN] - Update package lists"
        log_info "[DRY RUN] - Upgrade stable packages"
        log_info "[DRY RUN] - Upgrade rolling packages from unstable"
        log_info "[DRY RUN] - Run autoremove for cleanup"
        return 0
    fi
    
    # Update package lists first
    log_info "Updating package lists..."
    check_apt_lock || return 1
    if ! apt-get update; then
        log_error "Failed to update package lists"
        return 1
    fi
    
    # Upgrade stable packages first (this respects our pinning)
    log_info "Upgrading stable packages..."
    check_apt_lock || return 1
    local apt_cmd="apt-get upgrade"
    if [[ "$YES" == true ]]; then
        apt_cmd="$apt_cmd -y"
    fi
    
    if ! DEBIAN_FRONTEND=noninteractive $apt_cmd; then
        log_warning "Some stable packages failed to upgrade"
        log_info "Continuing with rolling package upgrades..."
    else
        log_success "Stable packages upgraded successfully"
    fi
    
    # Then upgrade rolling packages from unstable
    log_info "Upgrading rolling packages from unstable..."
    upgrade_rolling_packages
    
    # Handle any remaining issues and cleanup
    log_info "Running final cleanup..."
    local autoremove_cmd="apt-get autoremove"
    if [[ "$YES" == true ]]; then
        autoremove_cmd="$autoremove_cmd -y"
    fi
    
    check_apt_lock || return 1
    if DEBIAN_FRONTEND=noninteractive $autoremove_cmd; then
        log_success "System cleanup completed"
    else
        log_warning "Autoremove encountered issues"
    fi
    
    log_success "Full system upgrade completed"
    log_info "Rolling packages: $(grep -c "^[^[:space:]]*$" "$ROLLING_PACKAGES_FILE" 2>/dev/null || echo 0)"
}

roll_package() {
    local package="$1"
    
    validate_package_name "$package" || return 1
    
    # Check if package is installed
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
        log_error "Package '$package' is not currently installed"
        log_info "Use '$PROGRAM_NAME install $package' to install from unstable"
        return 1
    fi
    
    # Check if already rolling
    if grep -q "^$package$" "$ROLLING_PACKAGES_FILE" 2>/dev/null; then
        log_warning "Package '$package' is already configured as rolling"
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would convert $package to rolling and upgrade from unstable"
        return 0
    fi
    
    # Check if package exists in unstable
    log_info "Checking if $package is available in unstable..."
    if ! package_exists "$package"; then
        log_warning "Package '$package' not found. Updating package lists..."
        check_apt_lock || return 1
        apt-get update
        if ! package_exists "$package"; then
            log_error "Package '$package' not found in any repository"
            return 1
        fi
    fi
    
    # Get current and available versions for user confirmation
    local current_version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)
    local unstable_version=$(apt-cache policy "$package" 2>/dev/null | grep -A1 "unstable" | tail -1 | awk '{print $1}' || echo "Unknown")
    
    log_info "Current version: $current_version"
    log_info "Unstable version: $unstable_version"
    
    if ! confirm_action "Convert $package to rolling status and upgrade to unstable?"; then
        log_info "Operation cancelled"
        return 0
    fi
    
    log_info "Converting $package to rolling status..."
    
    # Add to rolling list and create preference
    add_to_rolling_list "$package"
    create_package_preference "$package"
    pin_dependencies "$package"
    
    # Build apt command with optional -y flag
    local apt_cmd="apt-get install -t unstable"
    if [[ "$YES" == true ]]; then
        apt_cmd="$apt_cmd -y"
    fi
    
    # Upgrade to unstable version
    log_info "Upgrading $package to unstable version..."
    check_apt_lock || return 1
    if DEBIAN_FRONTEND=noninteractive $apt_cmd "$package"; then
        log_success "Successfully converted $package to rolling and upgraded from unstable"
        log_info "Package $package will now be updated during '$PROGRAM_NAME upgrade' operations"
    else
        log_error "Failed to upgrade $package from unstable"
        # Rollback changes
        log_warning "Rolling back changes due to upgrade failure..."
        remove_from_rolling_list "$package"
        remove_package_preference "$package"
        return 1
    fi
}

unroll_package() {
    local package="$1"
    
    validate_package_name "$package" || return 1
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would remove $package from rolling status"
        # Show which dependencies would be cleaned up
        if [[ -f "$ROLLING_DEPS_FILE" ]]; then
            local deps_to_remove=$(grep ":$package$" "$ROLLING_DEPS_FILE" | cut -d: -f1)
            if [[ -n "$deps_to_remove" ]]; then
                log_info "[DRY RUN] Would also remove dependencies: $deps_to_remove"
            fi
        fi
        return 0
    fi
    
    # Check if package is actually in rolling list
    if ! grep -q "^$package$" "$ROLLING_PACKAGES_FILE" 2>/dev/null; then
        log_warning "Package '$package' is not configured as rolling"
        return 1
    fi
    
    # Remove package from rolling list
    remove_from_rolling_list "$package"
    remove_package_preference "$package"
    
    # Handle dependencies
    if [[ -f "$ROLLING_DEPS_FILE" ]]; then
        # Find dependencies that were added for this package
        local deps_to_check=$(grep ":$package$" "$ROLLING_DEPS_FILE" | cut -d: -f1)
        
        for dep in $deps_to_check; do
            # Check if this dependency is needed by other rolling packages
            local other_parents=$(grep "^$dep:" "$ROLLING_DEPS_FILE" | grep -v ":$package$" | wc -l)
            
            if [[ $other_parents -eq 0 ]]; then
                log_info "Removing dependency $dep (no longer needed)"
                remove_from_rolling_list "$dep"
                remove_package_preference "$dep"
                # Remove from dependencies file
                sed -i "/^$dep:$package$/d" "$ROLLING_DEPS_FILE"
            else
                log_verbose "Keeping dependency $dep (still needed by other packages)"
                # Just remove this specific dependency relationship
                sed -i "/^$dep:$package$/d" "$ROLLING_DEPS_FILE"
            fi
        done
    fi
    
    log_success "Removed $package from rolling status"
    log_info "The package remains installed. Use 'apt remove $package' to uninstall it."
    log_info "Use 'apt update && apt upgrade' to potentially downgrade to stable version."
}

search_packages() {
    local query=$1
    [[ -z $query ]] && { log_error "Search query required"; return 1; }

    log_info "Searching for '$query'…"

    echo -e "${BOLD}Stable:${NC}"
    apt-cache search "$query" | head -10

    echo
    echo -e "${BOLD}Unstable:${NC}"
    apt-cache --names-only search "$query" \
      | awk '{print $1}' \
      | xargs -r apt-cache policy \
      | awk '/^\S/ {pkg=$1} /unstable/ && /Candidate:/ {print pkg}' \
      | head -10
}


show_status() {
    echo -e "${BOLD}$PROGRAM_NAME Status:${NC}"
    echo -e "${BOLD}===================${NC}"
    
    # Check if initialized
    if [[ -f "$UNSTABLE_SOURCES" && -f "$PREFERENCES_FILE" ]]; then
        echo -e "Status: ${GREEN}Initialized${NC}"
    else
        echo -e "Status: ${RED}Not initialized${NC} (run '$PROGRAM_NAME init')"
        return
    fi
    
    # Show sources status
    if [[ -f "$UNSTABLE_SOURCES" ]]; then
        echo -e "Unstable sources: ${GREEN}Configured${NC}"
    else
        echo -e "Unstable sources: ${RED}Missing${NC}"
    fi
    
    # Show preferences status
    if [[ -f "$PREFERENCES_FILE" ]]; then
        echo -e "APT preferences: ${GREEN}Configured${NC}"
    else
        echo -e "APT preferences: ${RED}Missing${NC}"
    fi
    
    # Count rolling packages
    local rolling_count=0
    if [[ -f "$ROLLING_PACKAGES_FILE" ]]; then
        rolling_count=$(grep -c "^[^[:space:]]*$" "$ROLLING_PACKAGES_FILE" 2>/dev/null || echo 0)
    fi
    echo "Rolling packages: $rolling_count"
    
    # Show last update
    if [[ -f "$LOG_FILE" ]]; then
        local last_update=$(grep "SUCCESS.*upgrade" "$LOG_FILE" | tail -1 | cut -d' ' -f1-2 | tr -d '[]')
        if [[ -n "$last_update" ]]; then
            echo "Last upgrade: $last_update"
        fi
    fi
}

validate_dependencies() {
    local issues_found=0
    
    if [[ ! -f "$ROLLING_DEPS_FILE" ]]; then
        return 0
    fi
    
    log_verbose "Validating dependency relationships..."
    
    # Check for orphaned dependencies
    while IFS=: read -r dep parent; do
        [[ -z "$dep" || -z "$parent" ]] && continue
        
        # Check if parent still exists as rolling package
        if ! grep -qx "$parent" "$ROLLING_PACKAGES_FILE"; then
            log_warning "Orphaned dependency: $dep (parent $parent no longer rolling)"
            ((issues_found++))
            
            # Auto-cleanup orphaned deps
            if [[ "$FORCE" == true ]]; then
                log_info "Auto-removing orphaned dependency $dep"
                remove_from_rolling_list "$dep"
                remove_package_preference "$dep"
                sed -i "/^$dep:$parent$/d" "$ROLLING_DEPS_FILE"
            fi
        fi
    done < "$ROLLING_DEPS_FILE"
    
    return $issues_found
}

check_system() {
    log_info "Performing system checks..."
    local issues_found=0
    
    # Check 1: Verify aptr is initialized
    log_verbose "Checking system initialization status..."
    if [[ ! -f "$UNSTABLE_SOURCES" || ! -f "$PREFERENCES_FILE" ]]; then
        log_error "System not properly initialized (run '$PROGRAM_NAME init')"
        log_verbose "Missing files: $([ ! -f "$UNSTABLE_SOURCES" ] && echo "$UNSTABLE_SOURCES ") $([ ! -f "$PREFERENCES_FILE" ] && echo "$PREFERENCES_FILE")"
        ((issues_found++))
    else
        log_success "System properly initialized"
        log_verbose "Found: $UNSTABLE_SOURCES and $PREFERENCES_FILE"
    fi
    
    # Check 2: Verify rolling packages file exists and is readable
    log_verbose "Checking rolling packages file..."
    if [[ ! -f "$ROLLING_PACKAGES_FILE" ]]; then
        log_warning "Rolling packages file not found"
        log_verbose "Expected location: $ROLLING_PACKAGES_FILE"
        ((issues_found++))
    else
        log_success "Rolling packages file exists"
        local package_count=$(grep -c "^[^[:space:]]*$" "$ROLLING_PACKAGES_FILE" 2>/dev/null || echo 0)
        log_verbose "Found $package_count rolling packages in $ROLLING_PACKAGES_FILE"
    fi
    
    # Check 3: Check for broken dependencies
    log_verbose "Checking for broken dependencies using apt-check..."
    local broken_deps=$(apt-check 2>&1 | grep -o "[0-9]\+;[0-9]\+" | cut -d';' -f2)
    if [[ -n "$broken_deps" && "$broken_deps" -gt 0 ]]; then
        log_error "Found $broken_deps broken dependencies"
        ((issues_found++))
        log_info "Run 'sudo apt --fix-broken install' to fix broken dependencies"
    else
        log_success "No broken dependencies found"
        log_verbose "apt-check reports system is clean"
    fi

    log_verbose "Validating dependency relationships..."
    validate_dependencies
    local dep_issues=$?
    if [[ $dep_issues -gt 0 ]]; then
        ((issues_found += dep_issues))
        log_info "Run with --force to auto-cleanup orphaned dependencies"
    fi
    
    # Check 4: Verify rolling packages are actually installed
    log_verbose "Verifying installation status of rolling packages..."
    if [[ -f "$ROLLING_PACKAGES_FILE" && -s "$ROLLING_PACKAGES_FILE" ]]; then
        local missing_packages=()
        local total_checked=0
        while IFS= read -r package; do
            [[ -z "$package" ]] && continue
            ((total_checked++))
            log_verbose "Checking installation status of $package..."
            if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
                missing_packages+=("$package")
                log_verbose "$package: NOT INSTALLED"
            else
                log_verbose "$package: installed"
            fi
        done < "$ROLLING_PACKAGES_FILE"
        
        if [[ ${#missing_packages[@]} -gt 0 ]]; then
            log_warning "Found ${#missing_packages[@]} rolling packages that are not installed:"
            printf '  - %s\n' "${missing_packages[@]}"
            ((issues_found++))
        else
            log_success "All rolling packages are properly installed"
            log_verbose "Verified $total_checked rolling packages"
        fi
    else
        log_verbose "No rolling packages file or file is empty - skipping installation check"
    fi
    
    # Check 5: Verify preference files for rolling packages exist
    log_verbose "Checking preference files for rolling packages..."
    if [[ -f "$ROLLING_PACKAGES_FILE" && -s "$ROLLING_PACKAGES_FILE" ]]; then
        local missing_prefs=()
        while IFS= read -r package; do
            [[ -z "$package" ]] && continue
            local pref_file="/etc/apt/preferences.d/aptr-${package}"
            log_verbose "Checking preference file for $package: $pref_file"
            if [[ ! -f "$pref_file" ]]; then
                missing_prefs+=("$package")
                log_verbose "$package: preference file MISSING"
            else
                log_verbose "$package: preference file exists"
            fi
        done < "$ROLLING_PACKAGES_FILE"
        
        if [[ ${#missing_prefs[@]} -gt 0 ]]; then
            log_warning "Found ${#missing_prefs[@]} rolling packages missing preference files:"
            printf '  - %s\n' "${missing_prefs[@]}"
            ((issues_found++))
            log_info "Run '$PROGRAM_NAME roll <package>' to recreate missing preferences"
        else
            log_success "All rolling packages have proper preference files"
        fi
    else
        log_verbose "No rolling packages to check preference files for"
    fi
    
    # Check 6: Look for orphaned preference files
    log_verbose "Scanning for orphaned preference files in /etc/apt/preferences.d..."
    local orphaned_prefs=()
    if [[ -d "/etc/apt/preferences.d" ]]; then
        for pref_file in /etc/apt/preferences.d/aptr-*; do
            [[ ! -f "$pref_file" ]] && continue
            local package=$(basename "$pref_file" | sed 's/^aptr-//')
            log_verbose "Examining preference file: $pref_file (package: $package)"
            if [[ ! "$pref_file" =~ aptr-preferences$ ]] && ! grep -q "^$package$" "$ROLLING_PACKAGES_FILE" 2>/dev/null; then
                orphaned_prefs+=("$package")
                log_verbose "$package: ORPHANED preference file found"
            else
                log_verbose "$package: preference file properly tracked"
            fi
        done
        
        if [[ ${#orphaned_prefs[@]} -gt 0 ]]; then
            log_warning "Found ${#orphaned_prefs[@]} orphaned preference files:"
            printf '  - %s\n' "${orphaned_prefs[@]}"
            ((issues_found++))
            log_info "Run '$PROGRAM_NAME unroll <package>' to clean up orphaned preferences"
        else
            log_success "No orphaned preference files found"
            log_verbose "All aptr preference files are properly tracked"
        fi
    else
        log_verbose "/etc/apt/preferences.d directory not found"
        ((issues_found++))
    fi

    # Check 7: Test repository connectivity
    log_verbose "Testing repository connectivity to unstable sources..."
    log_verbose "Using sources file: $UNSTABLE_SOURCES"
    check_apt_lock || return 1
    if timeout 10 apt-get update -qq -o Dir::Etc::sourcelist="$UNSTABLE_SOURCES" 2>/dev/null; then
        log_success "Unstable repository is reachable"
        log_verbose "Successfully updated package lists from unstable"
    else
        log_error "Cannot reach unstable repository"
        log_verbose "Failed to update from $UNSTABLE_SOURCES"
        ((issues_found++))
    fi
    
    # Check 8: Verify preference files are properly formatted
    log_verbose "Validating preference file syntax and format..."
    local checked_prefs=0
    for pref_file in /etc/apt/preferences.d/aptr-*; do
        [[ ! -f "$pref_file" ]] && continue
        ((checked_prefs++))
        log_verbose "Validating syntax of: $pref_file"
        # Check for basic structure
        if ! grep -q "^Package:" "$pref_file" || ! grep -q "^Pin:" "$pref_file" || ! grep -q "^Pin-Priority:" "$pref_file"; then
            log_warning "Preference file $pref_file appears malformed"
            log_verbose "Missing required fields in $pref_file"
            ((issues_found++))
        else
            log_verbose "$pref_file: syntax appears valid"
        fi
    done
    log_verbose "Checked $checked_prefs preference files for syntax"
    
    # Summary
    echo
    log_verbose "System check completed. Scanned $checked_prefs preference files and $(grep -c "^[^[:space:]]*$" "$ROLLING_PACKAGES_FILE" 2>/dev/null || echo 0) rolling packages"
    if [[ $issues_found -eq 0 ]]; then
        log_success "System check completed successfully - no issues found"
    else
        log_warning "System check completed with $issues_found issue(s) found"
        return 1
    fi
}

# Help function
show_help() {
    cat << EOF
${BOLD}$PROGRAM_NAME v$VERSION - APT Rolling Package Manager${NC}

A tool for managing mixed Debian systems with stable core packages and
rolling development packages from unstable.

${BOLD}USAGE:${NC}
    $PROGRAM_NAME [OPTIONS] <command> [arguments]

${BOLD}OPTIONS:${NC}
    -v, --verbose       Enable verbose output
    -n, --dry-run       Show what would be done without executing
    -f, --force         Skip confirmation prompts
    -y, --yes           Automatic yes to prompts (equivalent to apt -y)
    -s, --stable        Install from stable branch (use with install command)
    -h, --help          Show this help message
    --version           Show version information

${BOLD}COMMANDS:${NC}
    init                Initialize system for mixed package management
    install <pkg>       Install package from unstable (default)
    install -s <pkg>    Install package from stable (equivalent to apt install)
    list               List all rolling packages with versions
    upgrade            Upgrade all rolling packages to latest unstable
    system-upgrade     Upgrade both stable and rolling packages (full system)
    roll <pkg>         Convert installed package from stable to rolling (unstable)
    unroll <pkg>       Remove package from rolling status
    search <query>     Search for packages in both stable and unstable
    status             Show system status and configuration
    check              Check system integrity and rolling package status
    help               Show this help message

${BOLD}EXAMPLES:${NC}
    $PROGRAM_NAME init                     # Initialize the system
    $PROGRAM_NAME install python3-dev      # Install python3-dev from unstable
    $PROGRAM_NAME install -s nginx         # Install nginx from stable
    $PROGRAM_NAME -y install golang        # Install golang from unstable (no prompts)
    $PROGRAM_NAME install --stable systemd # Install systemd from stable
    $PROGRAM_NAME list                     # Show all rolling packages
    $PROGRAM_NAME upgrade -y               # Upgrade all rolling packages (no prompts)
    $PROGRAM_NAME upgrade --dry-run        # Preview upgrade actions
    $PROGRAM_NAME system-upgrade           # Full system upgrade (stable + rolling)
    $PROGRAM_NAME system-upgrade --dry-run # Preview full system upgrade
    $PROGRAM_NAME search golang            # Search for golang packages
    $PROGRAM_NAME roll python3-dev         # Convert python3-dev to rolling
    $PROGRAM_NAME unroll python3-dev       # Stop rolling python3-dev
    $PROGRAM_NAME check -v                 # Check system integrity

${BOLD}FILES:${NC}
    $UNSTABLE_SOURCES    Unstable repository configuration
    $PREFERENCES_FILE             APT pinning preferences
    $ROLLING_PACKAGES_FILE        List of rolling packages
    $LOG_FILE                Log file

${BOLD}NOTES:${NC}
    - Rolling packages are automatically pinned to unstable with high priority
    - Stable packages maintain higher priority for system stability
    - Use '$PROGRAM_NAME status' to check system configuration
    - Logs are written to $LOG_FILE

For more information, visit: https://github.com/domwxyz/aptr
EOF
}

show_version() {
    echo "$PROGRAM_NAME v$VERSION"
}

process_flag() {
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            return 0
            ;;
        -n|--dry-run)
            DRY_RUN=true
            return 0
            ;;
        -f|--force)
            FORCE=true
            return 0
            ;;
        -y|--yes)
            YES=true
            return 0
            ;;
        -s|--stable)
            STABLE=true
            return 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --version)
            show_version
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            return 1  # Not a flag
            ;;
    esac
}

parse_options() {
    local command=""
    local args=()
    
    # Single pass through all arguments
    while [[ $# -gt 0 ]]; do
        if process_flag "$1"; then
            # Flag was processed, continue
            shift
        else
            # Not a flag - must be command or argument
            if [[ -z "$command" ]]; then
                command="$1"
            else
                args+=("$1")
            fi
            shift
        fi
    done
    
    echo "$command" "${args[@]}"
}

# Main function
main() {
    # Parse options and get remaining arguments
    local args
    args=$(parse_options "$@")
    set -- $args
    
    local command="${1:-help}"
    
    # Set up lock for operations that modify system
    case "$command" in
        init|install|upgrade|system-upgrade|roll|unroll)
            check_root
            check_lock
            ;;
    esac

    # Validate package names for commands that use them
    case "$command" in
        "install"|"roll"|"unroll"|"search")
            if [[ -n "$2" ]] && ! validate_package_name "$2"; then
                log_error "Invalid package name: $2"
                exit 1
            fi
            ;;
    esac
    
    case "$command" in
        "init")
            init_system
            ;;
        "install")
            if [[ -z "$2" ]]; then
                log_error "Package name required for install command"
                exit 1
            fi
            install_package "$2"
            ;;
        "list")
            list_rolling_packages
            ;;
        "upgrade")
            if ! confirm_action "This will upgrade all rolling packages from unstable. Continue?"; then
                log_info "Upgrade cancelled"
                exit 0
            fi
            upgrade_rolling_packages
            ;;
        "system-upgrade")
            if ! confirm_action "This will upgrade both stable and rolling packages. Continue?"; then
                log_info "System upgrade cancelled"
                exit 0
            fi
            upgrade_system
            ;;
        "roll")
            if [[ -z "$2" ]]; then
                log_error "Package name required for roll command"
                exit 1
            fi
            roll_package "$2"
            ;;
        "unroll")
            if [[ -z "$2" ]]; then
                log_error "Package name required for unroll command"
                exit 1
            fi
            unroll_package "$2"
            ;;
        "search")
            if [[ -z "$2" ]]; then
                log_error "Search query required for search command"
                exit 1
            fi
            search_packages "$2"
            ;;
        "status")
            show_status
            ;;
        "check")
            check_system
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Ensure we're on a Debian-based system
if ! command -v apt &> /dev/null; then
    log_error "This tool requires APT package manager (Debian/Ubuntu)"
    exit 1
fi

# Run main function with all arguments
main "$@"
