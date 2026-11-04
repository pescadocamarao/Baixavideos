# BaixaVídeos — app iOS (projeto para gerar o .ipa)

App nativo de download de vídeos pro iPhone, em PT-BR:

1. **Analisar link** — cole a URL direta do vídeo (.mp4, .mov, .webm ou .m3u8). O app descobre tipo, tamanho e se o servidor aceita download paralelo (Range). Se for .m3u8 "master", ele lista as qualidades reais (1080p, 720p, 480p…).
2. **Assistir** — player nativo (AVPlayer) pra ver o vídeo *antes* de baixar, com título editável.
3. **Qualidade e conexões** — escolha a qualidade e quantas conexões paralelas usar: 1x, 4x, 8x ou 16x.
4. **Baixar e salvar** — motor estilo **aria2**: divide o arquivo em pedaços e baixa vários ao mesmo tempo, com progresso, velocidade (MB/s), tempo restante (ETA), grade de pedaços, pausar / retomar / cancelar. No HLS, baixa os segmentos em até 4 conexões e junta tudo num arquivo .ts único. Os vídeos ficam salvos na **Biblioteca** (pasta Documents/Videos do app), pra assistir, compartilhar (salvar em Arquivos/Fotos) ou excluir.

Visual: interface escura e compacta, tipografia técnica, verde-lima só nas ações e no progresso. Fila de downloads fixa no rodapé.

Por ser **nativo**, o app não sofre o bloqueio de CORS que limita a versão web — ele baixa direto do servidor, como qualquer app de download.

---

## ⚠️ Leia antes: o .ipa sai SEM assinatura

Este projeto **não** gera um .ipa pronto pra instalar direto. Ele gera um **.ipa sem assinatura** (unsigned). Isso é normal no mundo do sideload:

- **Compilar** (transformar o código neste projeto em app) acontece na nuvem, no **GitHub Actions** — de graça.
- **Assinar e instalar** no seu iPhone é um passo separado, feito por você com o **ESign, AltStore ou SideStore**, usando o **seu** Apple ID ou o **seu** certificado. É a assinatura que faz o iPhone aceitar o app.

Sem assinatura sua, o iPhone não abre o app. Não existe atalho honesto pra isso.

---

## O que você precisa

- Uma **conta gratuita no GitHub** (github.com) — é lá que o app é compilado.
- Um jeito de assinar: **ESign**, **AltStore** ou **SideStore** já instalados no iPhone, com seu Apple ID ou certificado.
- Paciência de uns 5–10 minutos na primeira vez.

## Passo a passo

### Parte 1 — Subir o projeto pro GitHub

1. Entre em **github.com** (com sua conta) e crie um repositório novo: botão **New** → nome qualquer (ex.: `baixavideos`) → **Create repository**. Pode ser privado.
2. Suba **todos os arquivos deste projeto** pro repositório (a pasta inteira: `project.yml`, `README.md`, a pasta `Sources/` e a pasta `.github/` — a `.github` é escondida, mas é a mais importante: é ela que manda compilar).
3. Confirme que os arquivos apareceram na página do repositório.

> **Franqueza:** subir a pasta inteira pelo iPhone é impraticável — o Safari do iPhone não sobe pastas, e a pasta `.github` é escondida. Faça essa parte **de qualquer computador** (Windows, Mac, tanto faz), direto pelo site do GitHub no navegador, uma vez só. Depois da primeira vez, acompanhar as builds e baixar o .ipa dá pra fazer pelo iPhone sem problema.

### Parte 2 — Compilar e baixar o .ipa

4. No repositório, abra a aba **Actions** (se ela pedir, ative os workflows).
5. À esquerda, toque em **Build IPA** → botão **Run workflow** → **Run workflow**.
6. Espere a build ficar verde (✓). Ela instala o XcodeGen, gera o projeto e compila o app **sem assinatura**.
7. Abra a build concluída e, no fim da página, baixe o artifact **BaixaVideos-unsigned-ipa**.
8. O download é um **.zip do GitHub** — dentro dele está o arquivo que importa: **`BaixaVideos-unsigned.ipa`**. Extraia o .ipa do zip (no iPhone: app Arquivos → tocar no zip).

### Parte 3 — Assinar e instalar no iPhone

9. Abra o **ESign** (ou AltStore/SideStore) e importe o `BaixaVideos-unsigned.ipa`.
10. Assine com o **seu** Apple ID ou o **seu** certificado e instale.
11. Se o iPhone pedir, ative o **Modo Desenvolvedor** (Ajustes → Privacidade e Segurança → Modo Desenvolvedor) e **confie** no certificado (Ajustes → Geral → VPN e Gerenciamento de Dispositivo).

## ⏰ Aviso honesto sobre a assinatura gratuita

- Com **Apple ID gratuito**, o app **expira em 7 dias** — depois disso ele para de abrir até você assinar e instalar de novo.
- A assinatura gratuita também **conta na cota de App IDs** da conta (a mesma cota do AltStore/SideStore). Se a sua cota já estiver cheia, a instalação vai falhar até liberar espaço ou usar outro Apple ID/certificado.
- Com **certificado pago próprio (válido por 1 ano)**, o app dura o ano inteiro sem re-assinar.

## Novidades da v2.0

- Interface nova em abas (Baixar · Downloads · Biblioteca), sem passo a passo, só ícones e o essencial.
- Player estilo VLC: toque duplo nas laterais volta/avança 10s, arrastar na horizontal busca no vídeo, arrastar na vertical ajusta brilho (esquerda) e volume (direita), pinça/botão alterna o zoom (preencher a tela), velocidades de 0,5x a 2x, Picture in Picture, print do quadro atual direto pras Fotos e atalho pra abrir no VLC.
- Biblioteca com miniaturas, busca, ordenação (data, nome, tamanho), filtro (Todos/MP4/HLS), renomear, compartilhar e apagar.
- Downloads pausados sobrevivem ao fechamento do app: a fila e os pedaços ficam salvos e dá pra retomar quando reabrir.
- Qualidade: o app agora se apresenta como Safari de desktop pros servidores (vários CDNs só liberam as qualidades altas assim) e, quando o link colado é de uma playlist de qualidade única, ele procura sozinho a playlist master com todas as variantes.

## Limites desta versão (v2.0)

- HLS **criptografado** (playlists com `#EXT-X-KEY`, ex.: alguns players protegidos) não é suportado — o app avisa quando encontra um.
- Arquivo de servidor **sem suporte a Range**: o download é contínuo (1 conexão) e, se pausar, ele recomeça do zero. Com Range, pausar/retomar reaproveita os pedaços já baixados.
- O download roda com o app aberto/em uso. Download em segundo plano com o app fechado fica pra uma próxima versão.

## Como o projeto funciona (pra quem for mexer)

- `project.yml` — descrição do projeto pro **XcodeGen** (ele gera o `.xcodeproj` na build; por isso não há `.xcodeproj` neste pacote).
- `Sources/BaixaVideos/` — código SwiftUI (iOS 16+), sem dependências externas.
- `.github/workflows/build-ipa.yml` — a receita da build na nuvem.
- Sem conta, sem servidor, sem tracking: o app só acessa as URLs que você cola e guarda os vídeos no próprio aparelho.
