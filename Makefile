include luggage/luggage.make
include config.mk
USE_PKGBUILD=1
PB_EXTRA_ARGS+= --info "./Package/PackageInfo"
TITLE=Crypt
GITVERSION=$(shell ./Package/build_no.sh)
BUNDLE_VERSION=$(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Crypt/Info.plist")
PACKAGE_VERSION=${BUNDLE_VERSION}.${GITVERSION}
REVERSE_DOMAIN=com.grahamgilbert
PACKAGE_NAME=${TITLE}
PAYLOAD=\
	pack-plugin\
	pack-checkin \
	pack-escrow \
	pack-scripts \
	remove-xattrs

SWIFT_BUILD_DIR=.build/apple/Products/Release

# Crypt.bundle's CFBundleVersion. A timestamp always increases and sits above
# upstream's commit-count build numbers, so the installer never treats this
# bundle as older than one already on the Mac. Override it to build a tag:
# make dist CRYPT_BUILD_NUMBER=202610061522
CRYPT_BUILD_NUMBER ?= $(shell date -u +%Y%m%d%H%M)

.PHONY: test coverage version lint

# Keep the version reported by `checkin --version` in step with the bundle.
version:
	@/usr/bin/sed -i '' 's/^let cryptVersion = .*/let cryptVersion = "${BUNDLE_VERSION}"/' Sources/checkin/Version.swift

run:
	swift run checkin --help

test:
	swift test

coverage:
	swift test --enable-code-coverage

lint:
	swift build -Xswiftc -warnings-as-errors 2>/dev/null || swift build

build: check_variables clean-crypt build_binary
	xcodebuild -project Crypt.xcodeproj -configuration Release -scheme Crypt -derivedDataPath ./build OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_IDENTITY="${DEV_APP_CERT}" CRYPT_BUILD_NUMBER="${CRYPT_BUILD_NUMBER}"


clean-crypt:
	@sudo rm -rf build
	@sudo rm -rf .build
	@sudo rm -rf Crypt.pkg

pack-plugin: build l_private_etc
	@sudo ${RM} -rf ${WORK_D}
	@sudo mkdir -p ${WORK_D}/private/etc/newsyslog.d
	@sudo ${CP} Package/newsyslog.d/crypt.conf ${WORK_D}/private/etc/newsyslog.d/crypt.conf
	@sudo mkdir -p ${WORK_D}/Library/Security/SecurityAgentPlugins
	@sudo ${CP} -R build/Build/Products/Release/Crypt.bundle ${WORK_D}/Library/Security/SecurityAgentPlugins/Crypt.bundle

pack-scripts:
	@sudo ${INSTALL} -o root -g wheel -m 755 Package/postinstall ${SCRIPT_D}
	@sudo ${INSTALL} -o root -g wheel -m 755 Package/preinstall ${SCRIPT_D}

# swift build produces one universal binary from both slices, so there is no
# lipo step and no separate toolchain to point at.
build_binary: version
	MACOSX_DEPLOYMENT_TARGET=13.0 swift build -c release --arch arm64 --arch x86_64 --product checkin
	@mkdir -p build
	@/bin/cp ${SWIFT_BUILD_DIR}/checkin build/checkin
	@sudo chown root:wheel build/checkin
	@sudo chmod 755 build/checkin


sign_binary: build_binary
	codesign --timestamp --force --deep -s "${DEV_APP_CERT}" build/checkin

pack-checkin: l_Library l_Library_LaunchDaemons build_binary sign_binary
	@sudo mkdir -p ${WORK_D}/Library/Crypt
	@sudo ${CP} build/checkin ${WORK_D}/Library/Crypt/checkin
	@sudo chown -R root:wheel ${WORK_D}/Library/Crypt
	@sudo chmod 755 ${WORK_D}/Library/Crypt/checkin
	@sudo chown -R root:wheel ${WORK_D}
	@sudo ${INSTALL} -m 644 -g wheel -o root Package/com.grahamgilbert.crypt.plist ${WORK_D}/Library/LaunchDaemons

# The Managed Encryption Escrow window, its privileged helper and the helper's
# LaunchDaemon ride in this package; there is no separate installer.
ESCROW_APP_PATH=Applications/Utilities/Managed Encryption Escrow.app

pack-escrow: l_Library_LaunchDaemons
	$(MAKE) -C ManagedEncryptionEscrow app VERSION="${PACKAGE_VERSION}" SIGNING_IDENTITY_APP="${DEV_APP_CERT}"
	@sudo mkdir -p ${WORK_D}/Applications/Utilities
	@sudo /usr/bin/ditto "ManagedEncryptionEscrow/build/pkg-root/${ESCROW_APP_PATH}" "${WORK_D}/${ESCROW_APP_PATH}"
	@sudo chown -R root:wheel ${WORK_D}/Applications
	@sudo chmod 775 ${WORK_D}/Applications
	@sudo chmod 755 ${WORK_D}/Applications/Utilities
	@sudo ${INSTALL} -m 644 -g wheel -o root Package/com.grahamgilbert.crypt.helper.plist ${WORK_D}/Library/LaunchDaemons

# luggage calls this after it writes the component plist and before pkgbuild.
# Turning off the version check installs the bundle even over a newer one, so
# a rollback also lands.
modify_packageroot:
	@i=0; while sudo plutil -extract "$$i" xml1 -o /dev/null "${SCRATCH_D}/luggage.pkg.component.plist" 2>/dev/null; do \
		sudo plutil -replace "$$i.BundleIsVersionChecked" -bool NO "${SCRATCH_D}/luggage.pkg.component.plist"; \
		sudo plutil -replace "$$i.BundleIsRelocatable" -bool NO "${SCRATCH_D}/luggage.pkg.component.plist"; \
		i=$$((i + 1)); \
	done

dist: pkg
	@sudo rm -f Distribution
	@sed "s/replace_version/${PACKAGE_VERSION}/g" Package/Distribution-Template > Distribution
	@sudo productbuild --distribution Distribution --package-path . --sign "${DEV_INSTALL_CERT}" Crypt-${PACKAGE_VERSION}.pkg
	@sudo rm -f Crypt.pkg
	@sudo rm -f Distribution

notarize:
	@./notarize.sh "${APPLE_ACC_USER}" "${APPLE_ACC_PWD}" "./Crypt.pkg"

remove-xattrs:
	@sudo /usr/bin/xattr -rd com.dropbox.attributes ${WORK_D}
	@sudo /usr/bin/xattr -rd com.dropbox.internal ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.ResourceFork ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.FinderInfo ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.metadata:_kMDItemUserTags ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.metadata:kMDItemFinderComment ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.metadata:kMDItemOMUserTagTime ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.metadata:kMDItemOMUserTags ${WORK_D}
	@sudo /usr/bin/xattr -rd com.apple.metadata:kMDItemStarRating ${WORK_D}
	@sudo /usr/bin/xattr -rd com.dropbox.ignored ${WORK_D}

check_variables:
ifndef DEV_INSTALL_CERT
$(error "DEV_INSTALL_CERT" is not set)
endif
ifndef DEV_APP_CERT
$(error "DEV_APP_CERT" is not set)
endif
ifndef APPLE_ACC_USER
$(error "APPLE_ACC_USER" is not set)
endif
ifndef APPLE_ACC_PWD
$(error "APPLE_ACC_PWD" is not set)
endif
