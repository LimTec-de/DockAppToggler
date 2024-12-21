# DockAppToggler

A macOS utility that enhances Dock functionality by allowing you to toggle app visibility with a single click.

## Features

- Click on a Dock icon to toggle app visibility
- Seamless integration with macOS
- Requires accessibility permissions to function

## Building from Source

### Prerequisites

- Xcode 14.0 or later
- macOS 13.0 or later
- Apple Developer Account (for signing and notarization)
- Ruby (for Fastlane)

### Build Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/DockAppToggler.git
   cd DockAppToggler
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Edit `fastlane/.env` and update these variables:
   - `BUNDLE_ID`: Your app's bundle identifier
   - `TEAM_ID`: Your Apple Developer Team ID

4. Build the app:
   ```bash
   # Just build
   bundle exec fastlane mac build
   
   # Build, sign, and notarize
   bundle exec fastlane mac release
   ```

### Setting up Code Signing

1. Export your Developer ID certificate as a .p12 file from Keychain Access
2. Create an App Store Connect API Key in App Store Connect
3. Set up the following environment variables for CI/CD:
   - `BUILD_CERTIFICATE_BASE64`: Your base64-encoded .p12 certificate
   - `P12_PASSWORD`: Your .p12 file password
   - `KEYCHAIN_PASSWORD`: Any password for a temporary keychain
   - `ASC_KEY_ID`: App Store Connect API Key ID
   - `ASC_ISSUER_ID`: App Store Connect Issuer ID
   - `ASC_KEY_CONTENT`: App Store Connect API Key content

## Installation

1. Download the latest release from the GitHub releases page
2. Move DockAppToggler.app to your Applications folder
3. Launch the app
4. Grant accessibility permissions when prompted

## Development

The project uses Swift Package Manager for dependency management. To open in Xcode:

```bash
open Package.swift
```

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request