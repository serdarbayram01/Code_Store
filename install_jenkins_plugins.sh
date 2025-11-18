#!/bin/bash

################################################################################
# Jenkins Plugin Installation Script
# Bu script, Jenkins sunucusuna plugin yükler
################################################################################

set -e

# Log dosyası
LOG_FILE="${LOG_FILE:-/tmp/jenkins_plugins_install.log}"

# Renkli çıktı için
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Jenkins yapılandırması
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASSWORD="${JENKINS_PASSWORD:-}"

# Plugin listesi (kullanıcının istediği pluginler)
PLUGINS=(
    "docker"
    "docker-commons"
    "docker-workflow"
    "docker-api"
    "docker-build-step"
    "dependency-check-jenkins-plugin"
    "temurin"
    "eclipse-temurin"
    "sonar"
    "pipeline-stage-view"
    "blueocean"
)

# Plugin isimlerinin Jenkins plugin ID'lerine mapping
declare -A PLUGIN_IDS=(
    ["docker"]="docker-plugin"
    ["docker-commons"]="docker-commons"
    ["docker-workflow"]="docker-workflow"
    ["docker-api"]="docker-api"
    ["docker-build-step"]="docker-build-step"
    ["dependency-check-jenkins-plugin"]="dependency-check-jenkins-plugin"
    ["temurin"]="temurin"
    ["eclipse-temurin"]="adoptopenjdk"
    ["sonar"]="sonar"
    ["pipeline-stage-view"]="pipeline-stage-view"
    ["blueocean"]="blueocean"
)

# Alternatif plugin ID'leri (bazı pluginler farklı ID ile kurulabilir)
declare -A PLUGIN_ALT_IDS=(
    ["docker-api"]="docker-java-api"
    ["temurin"]="adoptium-temurin"
    ["eclipse-temurin"]="adoptopenjdk"
)

# Temurin için alternatif ID listesi
TEMURIN_ALTERNATIVES=("adoptium-temurin" "eclipse-temurin" "adoptopenjdk")

################################################################################
# Fonksiyonlar
################################################################################

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Jenkins'in çalışıp çalışmadığını kontrol et
check_jenkins_running() {
    print_info "Jenkins bağlantısı kontrol ediliyor: $JENKINS_URL"
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$JENKINS_URL" || echo "000")
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "403" ] || [ "$http_code" = "401" ]; then
        print_success "Jenkins erişilebilir (HTTP: $http_code)"
        return 0
    else
        if netstat -tln 2>/dev/null | grep -q ":8080" || ss -tln 2>/dev/null | grep -q ":8080"; then
            print_success "Jenkins portu (8080) açık"
            return 0
        else
            print_error "Jenkins'e erişilemiyor: $JENKINS_URL (HTTP: $http_code)"
            return 1
        fi
    fi
}

# Jenkins admin şifresini al
get_jenkins_password() {
    if [ -z "$JENKINS_PASSWORD" ]; then
        if [ -f "/var/lib/jenkins/secrets/initialAdminPassword" ]; then
            JENKINS_PASSWORD=$(cat /var/lib/jenkins/secrets/initialAdminPassword)
            print_info "Jenkins initial admin şifresi okundu"
        else
            print_warning "JENKINS_PASSWORD ayarlanmamış"
            exit 1
        fi
    fi
}

# Plugin'in yüklü olup olmadığını kontrol et
check_plugin_installed() {
    local plugin_id=$1
    local response=$(curl -s -u "$JENKINS_USER:$JENKINS_PASSWORD" \
        "$JENKINS_URL/pluginManager/api/json?depth=1" 2>&1)
    
    if echo "$response" | grep -q "\"shortName\":\"$plugin_id\""; then
        return 0
    else
        return 1
    fi
}

# Plugin versiyonunu al
get_plugin_version() {
    local plugin_id=$1
    local response=$(curl -s -u "$JENKINS_USER:$JENKINS_PASSWORD" \
        "$JENKINS_URL/pluginManager/api/json?depth=1" 2>&1)
    
    local version=$(echo "$response" | grep -o "\"shortName\":\"$plugin_id\"[^}]*\"version\":\"[^\"]*\"" | grep -o "\"version\":\"[^\"]*\"" | cut -d'"' -f4)
    
    if [ -n "$version" ]; then
        echo "$version"
    else
        if command -v jq &> /dev/null; then
            version=$(echo "$response" | jq -r ".plugins[] | select(.shortName==\"$plugin_id\") | .version" 2>/dev/null)
            if [ -n "$version" ] && [ "$version" != "null" ]; then
                echo "$version"
            fi
        fi
    fi
    
    if [ -z "$version" ]; then
        echo "N/A"
    fi
}

# Jenkins CLI jar dosyasını indir
download_jenkins_cli() {
    local cli_jar="/tmp/jenkins-cli.jar"
    
    if [ ! -f "$cli_jar" ]; then
        curl -sSL "$JENKINS_URL/jnlpJars/jenkins-cli.jar" -o "$cli_jar" 2>&1
        if [ $? -eq 0 ] && [ -f "$cli_jar" ]; then
            return 0
        else
            return 1
        fi
    fi
    return 0
}

# Jenkins CLI ile plugin yükleme
install_plugin_via_cli() {
    local plugin_id=$1
    local cli_jar="/tmp/jenkins-cli.jar"
    
    if [ ! -f "$cli_jar" ]; then
        if ! download_jenkins_cli; then
            return 1
        fi
    fi
    
    java -jar "$cli_jar" -s "$JENKINS_URL" -auth "$JENKINS_USER:$JENKINS_PASSWORD" \
        install-plugin "$plugin_id" -deploy > /tmp/jenkins_cli_output.log 2>&1
    
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# REST API ile plugin yükleme
install_plugin_via_rest_api() {
    local plugin_id=$1
    
    # CSRF token al
    local crumb=$(curl -s -u "$JENKINS_USER:$JENKINS_PASSWORD" \
        "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>&1)
    
    if [ -n "$crumb" ] && [ "$crumb" != "404" ]; then
        local crumb_header="-H \"$(echo $crumb | cut -d: -f1):$(echo $crumb | cut -d: -f2)\""
    else
        local crumb_header=""
    fi
    
    # Jenkins REST API ile plugin yükleme
    local xml_data="<install plugin=\"$plugin_id@latest\" />"
    
    local http_code=$(curl -s -w "%{http_code}" -o /tmp/jenkins_plugin_response.log \
        -X POST \
        -u "$JENKINS_USER:$JENKINS_PASSWORD" \
        -H "Content-Type: application/xml" \
        -H "Accept: application/xml" \
        $crumb_header \
        --data "$xml_data" \
        "$JENKINS_URL/pluginManager/installNecessaryPlugins" 2>&1)
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "403" ]; then
        return 0
    else
        return 1
    fi
}

# Plugin yükleme
install_plugin() {
    local plugin_name=$1
    local plugin_id=${PLUGIN_IDS[$plugin_name]}
    
    if [ -z "$plugin_id" ]; then
        plugin_id="$plugin_name"
    fi
    
    # Plugin zaten yüklü mü kontrol et (ana ID ve alternatif ID ile)
    if check_plugin_installed "$plugin_id"; then
        print_success "Plugin zaten yüklü: $plugin_name"
        return 0
    fi
    
    # Alternatif ID ile kontrol et
    local alt_id=${PLUGIN_ALT_IDS[$plugin_name]}
    if [ -n "$alt_id" ] && check_plugin_installed "$alt_id"; then
        print_success "Plugin zaten yüklü: $plugin_name (alternatif ID: $alt_id)"
        return 0
    fi
    
    print_info "Plugin kuruluyor: $plugin_name ($plugin_id)"
    
    # Jenkins CLI ile yükle
    if install_plugin_via_cli "$plugin_id"; then
        print_info "Plugin yükleme komutu gönderildi (CLI), bekleniyor..."
        sleep 10
        local retry=0
        while [ $retry -lt 20 ]; do
            if check_plugin_installed "$plugin_id"; then
                print_success "Plugin yüklendi: $plugin_name"
                return 0
            fi
            sleep 5
            ((retry++))
        done
    fi
    
    # CLI başarısızsa alternatif ID ile dene
    local alt_id=${PLUGIN_ALT_IDS[$plugin_name]}
    if [ -n "$alt_id" ]; then
        print_warning "CLI ile yükleme başarısız, alternatif ID deneniyor: $alt_id"
        if install_plugin_via_cli "$alt_id"; then
            print_info "Plugin yükleme komutu gönderildi (CLI - alternatif ID), bekleniyor..."
            sleep 10
            local retry=0
            while [ $retry -lt 20 ]; do
                if check_plugin_installed "$alt_id"; then
                    print_success "Plugin yüklendi: $plugin_name (alternatif ID ile)"
                    return 0
                fi
                sleep 5
                ((retry++))
            done
        fi
    fi
    
    # Temurin için tüm alternatif ID'leri dene
    if [ "$plugin_name" = "temurin" ]; then
        for alt_temurin in "${TEMURIN_ALTERNATIVES[@]}"; do
            print_warning "Temurin için alternatif ID deneniyor: $alt_temurin"
            if install_plugin_via_cli "$alt_temurin"; then
                print_info "Plugin yükleme komutu gönderildi (CLI - alternatif), bekleniyor..."
                sleep 10
                local retry=0
                while [ $retry -lt 20 ]; do
                    if check_plugin_installed "$alt_temurin"; then
                        print_success "Plugin yüklendi: $plugin_name (alternatif ID ile: $alt_temurin)"
                        return 0
                    fi
                    sleep 5
                    ((retry++))
                done
            fi
        done
    fi
    
    # Eclipse Temurin için alternatif ID'leri dene
    if [ "$plugin_name" = "eclipse-temurin" ]; then
        local eclipse_alternatives=("adoptopenjdk" "eclipse-temurin" "adoptium-temurin")
        for alt_eclipse in "${eclipse_alternatives[@]}"; do
            print_warning "Eclipse Temurin için alternatif ID deneniyor: $alt_eclipse"
            if install_plugin_via_cli "$alt_eclipse"; then
                print_info "Plugin yükleme komutu gönderildi (CLI - alternatif), bekleniyor..."
                sleep 10
                local retry=0
                while [ $retry -lt 20 ]; do
                    if check_plugin_installed "$alt_eclipse"; then
                        print_success "Plugin yüklendi: $plugin_name (alternatif ID ile: $alt_eclipse)"
                        return 0
                    fi
                    sleep 5
                    ((retry++))
                done
            fi
        done
    fi
    
    # CLI başarısızsa REST API ile dene
    print_warning "CLI ile yükleme başarısız, REST API deneniyor..."
    if install_plugin_via_rest_api "$plugin_id"; then
        print_info "Plugin yükleme komutu gönderildi (REST API), bekleniyor..."
        sleep 10
        local retry=0
        while [ $retry -lt 20 ]; do
            if check_plugin_installed "$plugin_id"; then
                print_success "Plugin yüklendi: $plugin_name"
                return 0
            fi
            sleep 5
            ((retry++))
        done
    fi
    
    print_error "Plugin yüklenemedi: $plugin_name"
    return 1
}

# Özet checklist yazdır
print_summary_checklist() {
    local success_plugins=("$@")
    local failed_plugins=()
    local total=${#PLUGINS[@]}
    local success_count=${#success_plugins[@]}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Başarısız pluginleri hesapla
    for plugin in "${PLUGINS[@]}"; do
        local found=0
        for success_plugin in "${success_plugins[@]}"; do
            if [ "$plugin" == "$success_plugin" ]; then
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            failed_plugins+=("$plugin")
        fi
    done
    
    local failed_count=${#failed_plugins[@]}
    
    {
        echo ""
        echo "================================================"
        echo "JENKINS PLUGIN KURULUM ÖZETİ"
        echo "================================================"
        echo "Tarih: $timestamp"
        echo "Jenkins URL: $JENKINS_URL"
        echo "Jenkins User: $JENKINS_USER"
        echo "Toplam Plugin Sayısı: $total"
        echo "================================================"
        echo ""
        echo "✅ BAŞARILI KURULUMLAR ($success_count/$total):"
        for plugin_name in "${success_plugins[@]}"; do
            local plugin_id=${PLUGIN_IDS[$plugin_name]}
            [ -z "$plugin_id" ] && plugin_id="$plugin_name"
            local version=$(get_plugin_version "$plugin_id")
            # Versiyon bulunamazsa alternatif ID ile dene
            if [ "$version" = "N/A" ]; then
                local alt_id=${PLUGIN_ALT_IDS[$plugin_name]}
                if [ -n "$alt_id" ]; then
                    version=$(get_plugin_version "$alt_id")
                fi
            fi
            printf "${GREEN}✓${NC} %-50s ${GREEN}v%s${NC}\n" "$plugin_name" "$version"
        done
        echo ""
        if [ ${#failed_plugins[@]} -gt 0 ]; then
            echo "❌ BAŞARISIZ KURULUMLAR ($failed_count/$total):"
            for plugin_name in "${failed_plugins[@]}"; do
                printf "${RED}✗${NC} %-50s ${RED}[BAŞARISIZ]${NC}\n" "$plugin_name"
            done
        fi
        echo ""
        echo "================================================"
    } | tee -a "$LOG_FILE"
}

# Tüm pluginleri yükle
install_all_plugins() {
    local failed_plugins=()
    local success_plugins=()
    local total=${#PLUGINS[@]}
    
    print_info "Jenkins Plugin Kurulumu Başlıyor"
    print_info "Toplam Plugin Sayısı: $total"
    echo ""
    
    for plugin in "${PLUGINS[@]}"; do
        if install_plugin "$plugin"; then
            success_plugins+=("$plugin")
        else
            failed_plugins+=("$plugin")
        fi
    done
    
    echo ""
    print_summary_checklist "${success_plugins[@]}"
    
    # Başarısız pluginleri tekrar dene
    if [ ${#failed_plugins[@]} -gt 0 ]; then
        print_warning "Bazı pluginler yüklenemedi, tekrar deneniyor..."
        sleep 10
        for plugin in "${failed_plugins[@]}"; do
            if install_plugin "$plugin"; then
                success_plugins+=("$plugin")
                failed_plugins=("${failed_plugins[@]/$plugin}")
            fi
        done
        echo ""
        print_summary_checklist "${success_plugins[@]}"
    fi
    
    if [ ${#failed_plugins[@]} -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Ana Script
################################################################################

main() {
    print_info "Jenkins Plugin Installation Script"
    echo ""
    
    if ! check_jenkins_running; then
        exit 1
    fi
    
    get_jenkins_password
    
    install_all_plugins
    
    print_info "Script tamamlandı!"
}

# Script çalıştırılıyor mu kontrol et
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
