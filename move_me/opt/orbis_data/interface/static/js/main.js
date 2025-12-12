// Orbis Mesh – zentrales JS
// - Light/Dark Mode via localStorage
// - Sidebar Toggle für mobile Layouts

(function () {
    const STORAGE_KEY = "orbis_theme";

    function applyTheme(theme) {
        const root = document.documentElement;
        const normalized = theme === "light" ? "light" : "dark";
        root.setAttribute("data-theme", normalized);
        localStorage.setItem(STORAGE_KEY, normalized);
    }

    function initTheme() {
        const stored = localStorage.getItem(STORAGE_KEY);
        if (stored === "light" || stored === "dark") {
            applyTheme(stored);
        } else {
            // default: dark
            applyTheme("dark");
        }
    }

    function initThemeToggle() {
        const toggleButtons = document.querySelectorAll("#themeToggle");
        if (!toggleButtons.length) return;

        toggleButtons.forEach((btn) => {
            btn.addEventListener("click", () => {
                const current = document.documentElement.getAttribute("data-theme") || "dark";
                const next = current === "dark" ? "light" : "dark";
                applyTheme(next);
            });
        });
    }

    function initSidebarToggle() {
        const toggle = document.getElementById("sidebarToggle");
        if (!toggle) return;

        toggle.addEventListener("click", () => {
            document.body.classList.toggle("sidebar-open");
        });

        // Close sidebar when clicking outside on mobile overlay
        document.addEventListener("click", (event) => {
            if (!document.body.classList.contains("sidebar-open")) return;
            const sidebar = document.getElementById("sidebar");
            if (!sidebar) return;

            if (!sidebar.contains(event.target) && event.target !== toggle) {
                document.body.classList.remove("sidebar-open");
            }
        });
    }

    function initFlashMessages() {
        const flashes = document.querySelectorAll(".flash");

        flashes.forEach(function (flash) {
            const category = flash.getAttribute("data-category");
            const closeBtn = flash.querySelector(".flash-close");

            if (closeBtn) {
                closeBtn.addEventListener("click", function () {
                    flash.remove();
                });
            }

            if (category === "success") {
                setTimeout(function () {
                    flash.classList.add("flash-hide");
                    // remove after transition if defined
                    setTimeout(function () {
                        if (flash.parentNode) {
                            flash.parentNode.removeChild(flash);
                        }
                    }, 300);
                }, 5000);
            }
        });
    }

    // --------------------------------------------------------------
    // Helfer für Mesh-Node-Darstellung
    // --------------------------------------------------------------

    function meshGetDbm(node) {
        if (typeof node.signal_dbm === "number") return node.signal_dbm;
        if (typeof node.rssi_dbm === "number") return node.rssi_dbm;
        if (typeof node.rssi === "number") return node.rssi;
        if (typeof node.signal === "string") {
            var m = node.signal.match(/-?\d+(\.\d+)?/);
            if (m) {
                return parseFloat(m[0]);
            }
        }
        return NaN;
    }

    function meshDbmToPercent(dbm) {
        if (!isFinite(dbm)) return null;
        var min = -95;
        var max = -35;
        var ratio = (dbm - min) / (max - min);
        if (ratio < 0) ratio = 0;
        if (ratio > 1) ratio = 1;
        return Math.round(ratio * 100);
    }

    function meshFormatDbm(dbm) {
        if (!isFinite(dbm)) return "–";
        return String(Math.round(dbm));
    }

    function meshFormatInt(value) {
        if (typeof value !== "number" || !isFinite(value)) {
            return "–";
        }
        return Math.round(value).toLocaleString("de-DE");
    }

    function meshFormatMbps(value) {
        if (typeof value !== "number" || !isFinite(value)) {
            return "–";
        }
        return value.toFixed(1);
    }

    function meshFormatLastSeen(seconds) {
        if (typeof seconds !== "number" || !isFinite(seconds)) {
            return "–";
        }
        return seconds.toFixed(2) + " s";
    }


    function initLocalNodeWidget() {
        const card = document.getElementById("local-node-card");
        if (!card) {
            return;
        }

        function applyStatus(data) {
            const macEl = document.getElementById("local-node-mac");
            if (macEl) {
                if (data && data.mac_wlan1) {
                    macEl.textContent = data.mac_wlan1;
                } else {
                    macEl.textContent = "unbekannt";
                }
            }

            const badges = document.querySelectorAll(".local-node-service");
            badges.forEach(function (badge) {
                const key = badge.dataset.key;
                if (!key || !data || !data.status) {
                    return;
                }

                const value = data.status[key];

                badge.classList.remove("badge-ok", "badge-bad");

                if (value === true) {
                    badge.textContent = "OK";
                    badge.classList.add("badge-ok");
                } else if (value === false) {
                    badge.textContent = "Error";
                    badge.classList.add("badge-bad");
                } else {
                    badge.textContent = "Unknown";
                }
            });
        }

        function refresh() {
            fetch("/api/local-node", {
                credentials: "same-origin",
            })
                .then(function (response) {
                    if (!response.ok) {
                        throw new Error("HTTP " + response.status);
                    }
                    return response.json();
                })
                .then(function (data) {
                    applyStatus(data);
                })
                .catch(function () {
                    const badges = document.querySelectorAll(".local-node-service");
                    badges.forEach(function (badge) {
                        badge.classList.remove("badge-ok");
                        badge.classList.add("badge-bad");
                        badge.textContent = "Error";
                    });
                });
        }

        refresh();
        setInterval(refresh, 1000);
    }

        function initMeshNodesWidget() {
        const localCard = document.getElementById("local-node-card");
        if (!localCard) {
            return;
        }

        const container = document.getElementById("mesh-node-container");
        if (!container) {
            return;
        }

        const expandedState = {};


        function clearExistingNodeCards() {
            const existing = container.querySelectorAll(".mesh-node-card");
            existing.forEach(function (card) {
                card.remove();
            });
        }

        
function createNodeCard(mac, node, timeoutSeconds) {
        const dbm = meshGetDbm(node);
        const pct = meshDbmToPercent(dbm);

        const lastSeen = typeof node.last_seen === "number" ? node.last_seen : null;
        const inactive =
            typeof timeoutSeconds === "number" &&
            lastSeen !== null &&
            lastSeen > timeoutSeconds;

        const throughput = typeof node.throughput === "number" ? node.throughput : null;
        const nexthop = node.nexthop || "–";

        const rxPackets = node.rx_packets;
        const rxDropMisc = node.rx_drop_misc;
        const rxBitrate = node.rx_bitrate_mbps;

        const txPackets = node.tx_packets;
        const txRetries = node.tx_retries;
        const txFailed = node.tx_failed;
        const txBitrate = node.tx_bitrate_mbps;

        // Card-Container
        const card = document.createElement("article");
        card.className = "card mesh-node-card"; // collapsed by default
        if (inactive) {
            card.classList.add("mesh-node-card--inactive");
        }

        // Titel: "Node <MAC>"
        const title = document.createElement("h2");
        title.className = "card-title";
        title.textContent = "Node ";

        const macSpan = document.createElement("span");
        macSpan.className = "mono";
        macSpan.style.color = "var(--accent)";
        macSpan.textContent = mac;

        title.appendChild(macSpan);
        card.appendChild(title);

        // Summary list (always visible)
        const summaryList = document.createElement("ul");
        summaryList.className = "card-list";

        const liSignal = document.createElement("li");
        const pctText = pct === null ? "–" : pct + " %";
        liSignal.innerHTML =
            'Signal: <span class="mono">' +
            pctText +
            "</span> (" +
            meshFormatDbm(dbm) +
            " dBm)";

        if (pct !== null) {
            const signalWrapper = document.createElement("div");
            signalWrapper.className = "node-signal";

            const signalBar = document.createElement("div");
            signalBar.className = "node-signal-bar";

            const signalMask = document.createElement("div");
            signalMask.className = "node-signal-mask";
            let masked = 100 - pct;
            if (!isFinite(masked)) {
                masked = 100;
            } else if (masked < 0) {
                masked = 0;
            } else if (masked > 100) {
                masked = 100;
            }
            signalMask.style.width = masked + "%";

            signalBar.appendChild(signalMask);
            signalWrapper.appendChild(signalBar);

            liSignal.appendChild(signalWrapper);
        }

        summaryList.appendChild(liSignal);
        card.appendChild(summaryList);

        // Details container (collapsible)
        const details = document.createElement("div");
        details.className = "mesh-node-details";

        // Liste 1: grundlegende Funkdaten (Details)
        const listMain = document.createElement("ul");
        listMain.className = "card-list";

        const liLastSeen = document.createElement("li");
        liLastSeen.innerHTML =
            'Last Seen: <span class="mono">' +
            meshFormatLastSeen(lastSeen) +
            "</span>";
        listMain.appendChild(liLastSeen);

        const liThroughput = document.createElement("li");
        liThroughput.innerHTML =
            'Est. Throughput: <span class="mono">' +
            meshFormatMbps(throughput) +
            "</span> Mb/s";
        listMain.appendChild(liThroughput);

        const liNexthop = document.createElement("li");
        liNexthop.innerHTML =
            'Next hop: <span class="mono">' + nexthop + "</span>";
        listMain.appendChild(liNexthop);

        details.appendChild(listMain);

        // Liste 2: Local RX
        const listRx = document.createElement("ul");
        listRx.className = "card-list";

        const liRxHeader = document.createElement("li");
        liRxHeader.innerHTML = "<strong>Local RX</strong>";
        listRx.appendChild(liRxHeader);

        const liRxPackets = document.createElement("li");
        liRxPackets.innerHTML =
            'Packets: <span class="mono">' + meshFormatInt(rxPackets) + "</span>";
        listRx.appendChild(liRxPackets);

        const liRxDrop = document.createElement("li");
        liRxDrop.innerHTML =
            'Drop misc: <span class="mono">' + meshFormatInt(rxDropMisc) + "</span>";
        listRx.appendChild(liRxDrop);

        const liRxBitrate = document.createElement("li");
        liRxBitrate.innerHTML =
            'Bitrate: <span class="mono">' +
            meshFormatMbps(rxBitrate) +
            "</span> Mb/s";
        listRx.appendChild(liRxBitrate);

        details.appendChild(listRx);

        // Liste 3: Local TX
        const listTx = document.createElement("ul");
        listTx.className = "card-list";

        const liTxHeader = document.createElement("li");
        liTxHeader.innerHTML = "<strong>Local TX</strong>";
        listTx.appendChild(liTxHeader);

        const liTxPackets = document.createElement("li");
        liTxPackets.innerHTML =
            'Packets: <span class="mono">' + meshFormatInt(txPackets) + "</span>";
        listTx.appendChild(liTxPackets);

        const liTxRetries = document.createElement("li");
        liTxRetries.innerHTML =
            'Retries: <span class="mono">' + meshFormatInt(txRetries) + "</span>";
        listTx.appendChild(liTxRetries);

        const liTxFailed = document.createElement("li");
        liTxFailed.innerHTML =
            'Failed: <span class="mono">' + meshFormatInt(txFailed) + "</span>";
        listTx.appendChild(liTxFailed);

        const liTxBitrate = document.createElement("li");
        liTxBitrate.innerHTML =
            'Bitrate: <span class="mono">' +
            meshFormatMbps(txBitrate) +
            "</span> Mb/s";
        listTx.appendChild(liTxBitrate);

        details.appendChild(listTx);

        card.appendChild(details);

        // Footer mit Toggle-Button
        const footer = document.createElement("div");
        footer.className = "mesh-node-footer";

        const toggleBtn = document.createElement("button");
        toggleBtn.type = "button";
        toggleBtn.className = "mesh-node-toggle";
        const isExpanded = !!expandedState[mac];
        if (!isExpanded) {
            card.classList.add("mesh-node-collapsed");
        } else {
            card.classList.remove("mesh-node-collapsed");
        }
        toggleBtn.textContent = isExpanded ? "Collapse" : "Expand";

        toggleBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            const currentlyExpanded = !!expandedState[mac];
            const nextExpanded = !currentlyExpanded;
            expandedState[mac] = nextExpanded;
            if (nextExpanded) {
                card.classList.remove("mesh-node-collapsed");
                toggleBtn.textContent = "Collapse";
            } else {
                card.classList.add("mesh-node-collapsed");
                toggleBtn.textContent = "Expand";
            }
        });

        footer.appendChild(toggleBtn);
        card.appendChild(footer);

        return card;
        }

        function applyMeshNodes(data) {
            clearExistingNodeCards();

            if (!data) {
                return;
            }

            const nodes = data.node_status || data.nodes || {};
            const timeout =
                typeof data.node_timeout === "number"
                    ? data.node_timeout
                    : 30;

            const entries = Object.entries(nodes);
            if (!entries.length) {
                return;
            }

            entries.forEach(function ([mac, node]) {
                const card = createNodeCard(mac, node, timeout);
                // direkt nach dem Local-Node-Card in den Grid-Container hängen
                container.appendChild(card);
            });
        }

        function refresh() {
            fetch("/api/mesh-nodes", {
                credentials: "same-origin",
            })
                .then(function (response) {
                    if (!response.ok) {
                        throw new Error("HTTP " + response.status);
                    }
                    return response.json();
                })
                .then(function (data) {
                    applyMeshNodes(data);
                })
                .catch(function () {
                    // Bei Fehler: vorhandene Node-Cards entfernen
                    clearExistingNodeCards();
                });
        }

        refresh();
        setInterval(refresh, 1000);
    }



    document.addEventListener("DOMContentLoaded", function () {
        initTheme();
        initThemeToggle();
        initSidebarToggle();
        initLocalNodeWidget();
        initMeshNodesWidget();
        initFlashMessages();
    });
})();