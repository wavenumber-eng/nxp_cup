package com.wavenumber.nxpc.bridge.protocol

enum class NxpCupSystemAction(
    val wireName: String,
    val protocolValue: Int,
    val confirmation: Int,
) {
    RACE_START(
        "race_start",
        NxpCupProtocol.SYSTEM_ACTION_RACE_START,
        NxpCupProtocol.RACE_START_CONFIRMATION,
    ),
    STOP(
        "stop",
        NxpCupProtocol.SYSTEM_ACTION_STOP,
        0,
    ),
}

enum class NxpCupSystemActionRequestStatus(val wireName: String) {
    QUEUED("queued"),
    BUSY("busy"),
    UNAVAILABLE("unavailable"),
}

enum class NxpCupSystemActionOutcome(val wireName: String) {
    ACCEPTED("accepted"),
    NOT_READY("not_ready"),
    DENIED("denied"),
    FAILED("failed"),
    SUPERSEDED("superseded"),
    UNAVAILABLE("unavailable"),
}

data class NxpCupSystemActionResult(
    val action: NxpCupSystemAction,
    val outcome: NxpCupSystemActionOutcome,
    val detail: String,
)
