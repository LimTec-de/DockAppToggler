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

### Build Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/DockAppToggler.git
   cd DockAppToggler
   ```

2. Build the app:
   ```bash
   # Build the app
   swift build
   
   # Run the app
   swift run
   ```

### Setting up Code Signing

1. Open the project in Xcode
2. Select the target and update signing settings with your developer account
3. Build and run from Xcode, or archive for distribution

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