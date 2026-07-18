package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.VolunteerActivism
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

private data class Attribution(val repo: String, val note: String)

private val attributions = listOf(
    Attribution("my-whoop", "BLE protocol reverse-engineering"),
    Attribution("goose", "historical-data decode + offload format"),
)

/**
 * Support, attribution, and contact. Ports SupportView.swift.
 */
@Composable
fun SupportScreen(onOpenDiagnostics: () -> Unit) {
    ScreenScaffold(
        title = "Support",
        subtitle = "Help, diagnostics, project information, and contact details.",
    ) {
        SectionHeader("Help & Contact", overline = "Get in touch")

        // Diagnostics is support tooling, not a top-level app destination.
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                NoopButton(
                    text = "Diagnostics & Support",
                    leadingIcon = Icons.Filled.BugReport,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = onOpenDiagnostics,
                )
                Text(
                    "Create a redacted report and capture extra detail for the connected device.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }

        // Contact — a frosted row with a tinted glyph chip.
        NoopCard(padding = 18.dp) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                GlyphChip(Icons.Filled.Email, Palette.accent)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Get in touch", style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        "Questions, feedback, bugs - noopapp@tuta.io",
                        style = NoopType.subhead, color = Palette.textSecondary,
                    )
                }
            }
        }

        // Built on — grouped frosted card with hairline-divided attribution rows + accent chevrons.
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    GlyphChip(Icons.Filled.VolunteerActivism, Palette.accent)
                    Text("Built on", style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(
                    "This stands on community reverse-engineering. Huge thanks:",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                attributions.forEachIndexed { idx, a ->
                    if (idx > 0) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(Palette.hairline),
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Filled.ChevronRight,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(a.repo, style = NoopType.mono(12f), color = Palette.textPrimary)
                        Spacer(Modifier.width(6.dp))
                        Text("· ${a.note}", style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }

        // Disclaimer.
        NoopCard(padding = 18.dp) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.textTertiary)
                Text(
                    "Not affiliated with, endorsed by, or connected to WHOOP. Interoperability software for your own device and data. Not a medical device.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }
    }
}

/** A small tinted glyph chip — a rounded square wash behind a domain-tinted icon, the Bevel
 *  card-header treatment used across the connection/help screens. */
@Composable
private fun GlyphChip(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(tint.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
    }
}
