const ROTULOS = { calcada_obstruida: "Calçada obstruída", rampa_bloqueada: "Rampa bloqueada", travessia_barreira: "Travessia com barreira" };
const CORES = { pendente: "#d9480f", em_analise: "#f59f00", resolvido: "#2b8a3e", descartado: "#868e96" };
const STATUS = Object.keys(CORES);
const $ = (id) => document.getElementById(id);
let ponto = null, marcador = null, camada = null, mapa = null;

function escolher(lat, lon) {
  ponto = { latitude: lat, longitude: lon };
  $("local").textContent = `${lat.toFixed(4)}, ${lon.toFixed(4)}`;
  if (marcador) marcador.remove();
  marcador = L.marker([lat, lon]).addTo(mapa);
}

function item(r) {
  const li = document.createElement("li");
  li.innerHTML = '<span class="tag demo">demonstração</span><span class="tag st"></span><strong></strong> <span class="meta"></span><p></p>';
  if (r.fonte !== "sintetico") li.querySelector(".demo").remove();
  li.querySelector(".st").textContent = r.status;
  li.querySelector("strong").textContent = ROTULOS[r.categoria];
  li.querySelector(".meta").textContent = new Date(r.criado_em).toLocaleString("pt-BR");
  li.querySelector("p").textContent = r.descricao_sanitizada || "";
  if ($("token").value) {
    const sel = document.createElement("select");
    sel.setAttribute("aria-label", "Alterar status");
    STATUS.forEach((s) => sel.add(new Option(s, s, false, s === r.status)));
    sel.onchange = () => revisar(r.id, sel.value);
    li.appendChild(sel);
  }
  return li;
}

async function carregar() {
  const dados = await (await fetch("api/reports")).json();
  $("atualizado").textContent = new Date(dados.atualizado_em).toLocaleString("pt-BR");
  camada.clearLayers();
  $("lista").replaceChildren(...dados.itens.map(item));
  dados.itens.forEach((r) =>
    L.circleMarker([r.latitude, r.longitude], { radius: 9, color: CORES[r.status], fillOpacity: 0.8 })
      .bindPopup(`${ROTULOS[r.categoria]} — ${r.status}`).addTo(camada));
}

async function revisar(id, status) {
  const r = await fetch(`api/admin/reports/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${$("token").value}` },
    body: JSON.stringify({ status }),
  });
  $("msg").textContent = r.ok ? "Status atualizado." : "Falha na revisão (token inválido?).";
  carregar();
}

$("form").onsubmit = async (e) => {
  e.preventDefault();
  if (!ponto) { $("msg").textContent = "Escolha o local no mapa primeiro."; return; }
  const r = await fetch("api/reports", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...ponto, categoria: $("categoria").value, descricao: $("descricao").value || null }),
  });
  const corpo = await r.json();
  $("msg").textContent = r.ok ? `Relato registrado com status "${corpo.status}".` : `Erro: ${corpo.detail}`;
  if (r.ok) { $("descricao").value = ""; carregar(); }
};

$("geo").onclick = () => navigator.geolocation.getCurrentPosition(
  (p) => escolher(p.coords.latitude, p.coords.longitude),
  () => { $("msg").textContent = "Não foi possível obter sua localização."; });
$("token").onchange = carregar;

(async () => {
  const cfg = await (await fetch("api/config")).json();
  const [minLat, minLon, maxLat, maxLon] = cfg.bbox;
  $("versao").textContent = cfg.version;
  mapa = L.map("mapa").fitBounds([[minLat, minLon], [maxLat, maxLon]]);
  L.tileLayer("https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png", {
    maxZoom: 19, attribution: "© OpenStreetMap · estilo HOT, servidor OSM France" }).addTo(mapa);
  L.rectangle([[minLat, minLon], [maxLat, maxLon]], { color: "#0b5cad", fill: false, dashArray: "4" }).addTo(mapa);
  camada = L.layerGroup().addTo(mapa);
  mapa.on("click", (e) => escolher(e.latlng.lat, e.latlng.lng));
  carregar();
})();
