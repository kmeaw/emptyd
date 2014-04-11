# Emptyd

Server counterpart of [emptyc](https://github.com/kmeaw/emptyc), which
keeps track of SSH connections, pushes I/O over the wire, providing
an HTTP-interface for emptyc.

## Installation

    $ sudo gem install emptyd

For Mac OS X Mavericks users: if you have problems compiling native
extensions for eventmachine-le, try setting up ARCHFLAGS:

    $ sudo env ARCHFLAGS=-Wno-error=unused-command-line-argument-hard-error-in-future gem install emptyd

## Usage

TODO: Write usage instructions here

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
