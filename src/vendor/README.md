# Vendored dependencies

All Solidity dependencies required for the adapter and the standard OFT compatibility fixture are included as ordinary files. Import paths are resolved by the remappings in `foundry.toml`. No package manager, network access, `lib/`, submodule, or `node_modules/` is needed to build.

| Package | Pinned version | Upstream |
| --- | --- | --- |
| `@layerzerolabs/oft-evm` | 4.0.1 | [LayerZero devtools](https://github.com/LayerZero-Labs/devtools/tree/main/packages/oft-evm) |
| `@layerzerolabs/oapp-evm` | 0.4.1 | [LayerZero devtools](https://github.com/LayerZero-Labs/devtools/tree/main/packages/oapp-evm) |
| `@layerzerolabs/lz-evm-protocol-v2` | 3.0.168 | [LayerZero V2](https://github.com/LayerZero-Labs/LayerZero-v2) |
| `@openzeppelin/contracts` | 5.0.2 | [OpenZeppelin v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) |

Only the recursive Solidity import closure of `OFTAdapter.sol` and `OFT.sol` was copied from the pinned npm archives. The latter and ERC20 support the test-only remote OFT. Production uses OFTAdapter. Source files have no local modifications, including formatting. [DEPENDENCIES.json](DEPENDENCIES.json) records npm archive URLs, verified SHA-512 integrity values, and each included Solidity file's SHA-256. No upgradeable package or endpoint implementation is linked into the adapter.

LayerZero OFT/OApp and protocol interfaces carry MIT headers. The protocol's `AddressCast.sol` and `PacketV1Codec.sol` carry `LZBL-1.2` headers. Corresponding upstream texts are in [@layerzerolabs/LICENSE-MIT](@layerzerolabs/LICENSE-MIT) and [@layerzerolabs/LICENSE-LZBL-1.2](@layerzerolabs/LICENSE-LZBL-1.2); their pinned retrieval URLs and hashes are in [LICENSE-SOURCES.json](LICENSE-SOURCES.json). OpenZeppelin's MIT license is preserved at [@openzeppelin/contracts/LICENSE](@openzeppelin/contracts/LICENSE), from the v5.0.2 source repository.

Tests use the separately vendored `forge-std` v1.9.7 under `test/vendor/forge-std`. Its provenance file records the tag archive URL and SHA-256; its upstream MIT and Apache-2.0 license files are retained there. These dependencies are delivered, while downloads and working files under `test/scratch/` are disposable.
