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
	pack-scripts \
	remove-xattrs

SWIFT_BUILD_DIR=.build/apple/Products/Release

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
	xcodebuild -project Crypt.xcodeproj -configuration Release -scheme Crypt -derivedDataPath ./build OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_IDENTITY="${DEV_APP_CERT}"


clean-crypt:
	@sudo rm -rf build
	@sudo rm -rf .build
	@sudo rm -rf Crypt.pkg

pack-plugin: build l_private_etc
	@sudo ${RM} -rf ${WORK_D}
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
