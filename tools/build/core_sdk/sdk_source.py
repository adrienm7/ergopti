# tools/build/core_sdk/sdk_source.py
"""Fixed SDK source composition; no compiler, image or signing authority.

This is the existing SDK source roster, extracted from its operational owner.
The genuine source factory retains every physical input and issues the staged
image; this pure transform never accepts an admission Boolean or a receipt.
"""

import hashlib

ROWS = (
    (
        "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp",
        "99d8db4917f09054cda1b33575b3002a5d89b3fc730050dffa27d20410cd89d6",
        "96401b6241800495f79ae020f8573b3d10b40e54f65abf2ea89d8d27f03121c0",
        113525,
    ),
    (
        "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
        "ee8137014775653479b14eb315e7d919a7d99505c414a03094716b2f9f0acfc7",
        "b1a710b8579ae24cff197ec33c0e26d11f4219771ac446e2ae46c68c4616db1f",
        57780,
    ),
    (
        "src/apps/CoreService/observer-controls/positive.cpp",
        None,
        "f45a4e28c2521f01ce0d34eaa490c7570c6d246b2190fb1fc1cc6313cdd923d1",
        13802,
    ),
    (
        "src/apps/CoreService/observer-controls/production_negative.cpp",
        None,
        "fc13f33fadcf4eb623766655b1cf9642db86f5ba44677b8f3056c612726dc82d",
        479,
    ),
    (
        "src/apps/CoreService/observer-project.yml",
        None,
        "29a7073f5c923098e89d9ce1f74a912e7b68a80f4339cae6279da2d80165688a",
        5254,
    ),
    (
        "src/apps/CoreService/observer-support/OwnedRuntimeLifecycleContract.c",
        None,
        "36e55af172965f9d4831401ec3e0127fbf944332d05f66805bf99cbf6bda60d6",
        315,
    ),
    (
        "src/share/InstalledRuntimeConfirmedUpdatePeer.hpp",
        None,
        "02086d8597b4420c4c52b09daa3209bb01274e0c21eee633f1e8be468ec26b2c",
        30948,
    ),
    (
        "src/share/InstalledRuntimeMaintenanceAdmission.hpp",
        None,
        "fecd947dcb136fb2877055cc294c7279bb4970a716b75070ecbd9038f64a417b",
        11694,
    ),
    (
        "src/share/InstalledRuntimeMaintenanceObservation.hpp",
        None,
        "80b0bfcc12bb2d48e1633d0713930f750658fa28179035d5f2291f0b45f707dd",
        884,
    ),
    (
        "src/share/InstalledRuntimeMaintenancePeer.hpp",
        None,
        "7e39332b1ee88bc539cd9f1bc7c101afc48c411e93fc733f9a3d697aff0f1df6",
        10433,
    ),
    (
        "src/share/InstalledRuntimeProcessIdentity.hpp",
        None,
        "952247c89bb4a0edbef0cddf67af548b831f2aef63ab4853d35ff557869bab6a",
        8118,
    ),
    (
        "src/share/InstalledRuntimePublisher.hpp",
        None,
        "e097211520fc92b4751fda382b04a6055171c27b82d99a5bbb472869603017a1",
        17969,
    ),
    (
        "src/share/InstalledRuntimeUpdateApprovalCodec.hpp",
        None,
        "de14bc91485defeb5c63286aa5cd99b3ace872df7b5995decd5bad850d7295ee",
        6794,
    ),
    (
        "src/share/InstalledUserConfiguration.hpp",
        None,
        "8e9fc9da6e6bde812d02da9e7fad80ba6d227d5d4670ae6257417ce32faad18b",
        16204,
    ),
    (
        "src/share/OwnedRuntimeLifecycleContract.h",
        None,
        "318d8bbc2deab904914888d560a6ffc5537a8e9d48ccc42d50b9ae6077997474",
        494,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceCoreEndpoint.hpp",
        None,
        "15457f627b9856b3eab4b6f03e860147dfe65ab7ce7c4d7259971737e4df181d",
        8292,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceCoreEndpointBody.hpp",
        None,
        "484794a8814c12385dfdecb599f18b88bdda9addf4acba20c5516ef99a3c3bce",
        29058,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceFraming.hpp",
        None,
        "ee8d0016a3d04a54bfcfdd44f5dc6aab72d52202b1a9dd209163f5a38576fd6d",
        4422,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceLineage.hpp",
        None,
        "5cce0c8b932b3b3d4acb74ad914eff2e0e774767505683b586d308a759a438c0",
        7393,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceNativeSocket.hpp",
        None,
        "0443a222e2af5a0a1e5bb56990f98fec6334ae53ed6070b41454e04b6d4cb7a6",
        19356,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceResponseBoundary.hpp",
        None,
        "7c55684c1b5776c27267808201929b7575d8b2657daadb2c69fa542115e460d1",
        465,
    ),
    (
        "src/share/OwnedRuntimeMaintenanceWire.h",
        None,
        "2600c67513a9aa3ea69217e774fa3fdfe3f533d57494b54d5e41e46a2ef48652",
        2631,
    ),
    (
        "src/share/core_configuration/core_configuration.hpp",
        "503f29e8fd7bac528453a5d1409b125484b91bde86b45603f17a800991a9309e",
        "a28854cc677d1fb575c3eaf1026a9280fa9eaf505a8ee5ddc60243f7d53e1a89",
        16557,
    ),
    (
        "src/share/ergopti-owned-native-inventory.hpp",
        "5a033ca40c506b654f62fd3e1a0b9eee7a74396c8fd68f2319aba38173e92515",
        "5a033ca40c506b654f62fd3e1a0b9eee7a74396c8fd68f2319aba38173e92515",
        3791,
    ),
    (
        "src/share/ergopti-owned-queue-fence.hpp",
        "fd8893ef0b9f954a7fcabc7aadf29815874c9cc2695dd3157916e2cea3bd3c97",
        "fd8893ef0b9f954a7fcabc7aadf29815874c9cc2695dd3157916e2cea3bd3c97",
        3293,
    ),
    (
        "src/share/event_queue/event.hpp",
        "b893853af2473559d3fda1a5c57a459163256bfd83180f3a87e9695c7add6f79",
        "0b17b559752c9ae3ac6436f32a2b845cf0e71c2c4dc8aba19d756ec7bcce508e",
        19594,
    ),
    (
        "src/share/event_queue/queue.hpp",
        "8a4bd0ce779ef0229eb8cdfd25c76f871da7e775c5e3f8b67b1b2bffc3127034",
        "3ef32cc40fea5d46ef2f5aa172002bbf37da7e6d485b7ed31d2091a5a1e4ba0e",
        14972,
    ),
    (
        "src/share/hid_device_events_monitor.hpp",
        "2bce77247574040b2883c0d83b892d75f7bd83a01ac45deefde22e91c815d0e2",
        "089408b07bd7c81c39b3ead228c84b8beb66429a232e179d60bb3c28513d4218",
        13898,
    ),
    (
        "src/share/hs274-installed-baseline-client.hpp",
        None,
        "9d916cafe3711fbbf90d755e791602257d77d47f3fdc0780a58ed6e15415e17e",
        3942,
    ),
    (
        "src/share/hs274-installed-cli.hpp",
        None,
        "d199e2319476113829719e1dafc797b4271a4cb188d1c55eba1274e83f5282d3",
        19653,
    ),
    (
        "src/share/hs274-installed-readiness.hpp",
        None,
        "c81caf8dd0093fcb52d56a022db68472fe6c180846c4547859f9011c1cb6f356",
        4700,
    ),
    (
        "src/share/hs274-stream-cli.hpp",
        "674aae5284c7d4d1c6ea65dae898741a63922d595caeb5cc8559ce47eee47c67",
        "674aae5284c7d4d1c6ea65dae898741a63922d595caeb5cc8559ce47eee47c67",
        10397,
    ),
    (
        "src/share/hs274-stream-source.hpp",
        "4ebcd7324e1039ce019252762e827f0739d6de94075365a3a5f9826b6750d3e8",
        "90079eb79aec7d6d1efce6f8c46c3b8777ae96e47c8c6660b4941d76367e058a",
        31674,
    ),
    (
        "src/share/hs274-stream-runtime.hpp",
        "37c3c03b92b343cc55df565cb8e6e0cea6970679a355d2f356e8afd097a85475",
        "a62716e67ce79513464c8661468e260a62223ac7329a6dcce1d94126d47068a7",
        52059,
    ),
    (
        "src/share/manipulator/manipulators/post_event_to_virtual_devices/post_event_to_virtual_devices.hpp",
        "45ed1c9e8b560c9dcb1851325183b92273137e74657dd94d89ad00ee38c49538",
        "840426465175b166812a3ab9436475e0ba6807f8ca1dd7bc5f6b9205c8adb199",
        27836,
    ),
    (
        "src/share/manipulator/manipulators/post_event_to_virtual_devices/queue.hpp",
        "8f3c7a0d806ee6a7b121a8b9e52930fcc252d911524bf8ec7c6ed7d1a1f9ebc7",
        "0eb235b43c717865c2af5099627d07648e2c36e86cac62e02b9bedc3c5262f27",
        31778,
    ),
    (
        "src/share/monitor/event_tap_monitor.hpp",
        "7a351e9a3b0d348beaef9c9a6b5b13e61acc1ee4c5c4ad2f06ae9943d4a57780",
        "f1e8890e4167a2ff523420d662100e708f1b07e4235bd201d5516f6bf666dec5",
        20163,
    ),
    (
        "src/share/remap_runtime_console_control.hpp",
        None,
        "4eaa485d23f09edbf2c605bd57ebe7a9abc0f9e34a51465f0a0a765478500151",
        12274,
    ),
    (
        "src/share/remap_runtime_installed_capture.hpp",
        None,
        "6077db742a7dc18b1d3e041479bf3af89214b7c725ab38850c0afe06c169b678",
        35635,
    ),
    (
        "src/share/remap_runtime_installed_configuration.hpp",
        None,
        "173c77b95859d92816bf492a56707ed5d1715d6e25b64c7caedecb70961b6a64",
        6434,
    ),
    (
        "src/share/remap_runtime_installed_peer.hpp",
        None,
        "79f1c68beaedfedd5553f90c5fcdca4ff6768e935236f1e2eeba6909bc0038c9",
        10051,
    ),
    (
        "src/share/remap_runtime_vhd.hpp",
        "ca6d4cf40c726ab7c844fdae2bb7ff5dcee476cc2c061944ee76eab385aa1b65",
        "ee88cbcf04ef58d063333f14c52d733d8416e79cad45c8a9aafb1cab7fbd19dc",
        39755,
    ),
    (
        "vendor/Karabiner-DriverKit-VirtualHIDDevice/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp",
        "f622589c4fe303de4c36f362c59f9da000e31f21d6f733f7e5fef19593ca4dea",
        "4c085f4abdf33040e4b17785037689394d2617d68f85abbf1f6b8d72dab3269d",
        34050,
    ),
    (
        "vendor/vendor/include/pqrs/osx/cg_event_tap.hpp",
        "73123e10a08022d70b17dfb61904358e49d425476aa47bbb8a795e9d23f4b8d4",
        "4cb8f7273900c79cd0786a70a175a9fe287ce520cc787701682395bd4056c649",
        2608,
    ),
    (
        "vendor/vendor/include/pqrs/osx/hitoolbox/secure_event_input_monitor.hpp",
        "efc2cc3d66d2fe135af431a615dbb5b368ad8ed8c8f898448d5a9c8002612c5d",
        "ebd96e71731f8a06e6f65ebf47b74ba40425f13493a1ffae0bb88d4f4ab507b1",
        6215,
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_hid_device_events_monitor.hpp",
        "3e8b27e5f77bb0fc915ba8b561856b5ae8e02ae05610e4c7cd8c99c581bcaa55",
        "673e349b17d360b27d9ffa4f4a1c7c93a98d5dfbb1365220fd4f8ac107001e85",
        34372,
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_hid_manager.hpp",
        "c69d54f7ddde744a5c0308652443b91ce3b9258e6760e29efdbc934816521dec",
        "7b7811cc829307d55da5edc545abc4a22e415a74bddd11c74ac736978e534c03",
        15828,
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_service_monitor.hpp",
        "36d30acc6783c8d82c44e45a01e14d0797b14558655a52266e1a1225bad31705",
        "3eafd93fcc1a6b42f7bd810e93a29afdfe5b6b6fd9683a3b1e1fcb347559b70d",
        16010,
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp",
        "75fbd454f7c9291be4fb04534b1b328a007606177216f68c90d8b84005f7ae55",
        "aba5b269627c25dc805f79d3ddf5cdc742b49c94f9aead1d78d2fe2f6c13c847",
        40026,
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp",
        "1fdfeba1db4ac0df8d359bf6f900eef97271917034d24b14eeca676fb5d9c591",
        "ee82565ef9a8712e068a4bcc2a50934a9ab5f84c6d5e9a038e522b58f63bcbfd",
        28257,
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp",
        "2a07977e58b0767c8f1b824511b3b15abd21de1f27abb90f0c43ba5013f6a47a",
        "c25646bd5637d119e55037f9bdc06d24376975063f70ecb1f724261643ca7db5",
        12267,
    ),
    (
        "src/share/hs274-installed-intent.hpp",
        None,
        "479cb79864707bc017ecea2ea65aaf8104426943140b26292eafe868049e2273",
        6891,
    ),
    (
        "src/bin/cli/src/main.cpp",
        "2bcb6ab2eac56d7c0a051a08edee89492a0e6a8852c6d0e23c0bda8e36e077ef",
        "962bac224e17d29728b711e280be7aac115c663d78018eea24d5db9ca7dd217e",
        23544,
    ),
)

CORE_RECIPE = "src/apps/CoreService/project.yml"
CORE_RECIPE_PRE = "f9d73b714b13253f200618c875bbe9b1f139fa636992d0978dd970dc562751e1"


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def compose(base, current, inputs):
    """Extend the actual canonical outputs only after every fixed PRE is checked."""
    if type(base) is not dict or len(base) != 65:
        raise ValueError("Complete canonical source outputs are required")
    if type(current) is not dict or set(current) != {
        path for path, pre, _, _ in ROWS if pre is not None
    }:
        raise ValueError("Exact genuine SDK preimage roster is required")
    if type(inputs) is not dict or set(inputs) != {path for path, _, _, _ in ROWS}:
        raise ValueError("Exact fixed SDK source input roster is required")
    result = dict(base)
    for path, pre, post, size in ROWS:
        data = inputs[path]
        if type(data) is not bytes or len(data) != size or _digest(data) != post:
            raise ValueError("Fixed SDK source bytes changed")
        if pre is not None and (type(current[path]) is not bytes or _digest(current[path]) != pre):
            raise ValueError("Genuine SDK preimage differs")
        if pre is None and path in base:
            raise ValueError("New SDK source collides with the canonical generator")
        result[path] = data
    recipe = base.get(CORE_RECIPE)
    if type(recipe) is not bytes or _digest(recipe) != CORE_RECIPE_PRE:
        raise ValueError("Genuine production Core recipe differs")
    anchor = b"    sources:\n      - path: src\n"
    if recipe.count(anchor) != 1:
        raise ValueError("Production Core source anchor differs")
    result[CORE_RECIPE] = recipe.replace(
        anchor,
        b"    sources:\n      - path: observer-support/OwnedRuntimeLifecycleContract.c\n      - path: src\n",
        1,
    )
    if len(result) != 101 or len(ROWS) != 53:
        raise ValueError("Fixed SDK composition inventory differs")
    return tuple(sorted(result.items()))
