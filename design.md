# Ayax — Design System (`design.md`)

> Especificación portable para usar con cualquier IA o agente (Claude, Cursor, Copilot, v0, etc.).
> Pega o adjunta este archivo y pide construir pantallas "siguiendo el design system de Ayax".
> **El color y la tipografía salen de ayaxseguridad.com. No los cambies.**
> **Stack objetivo:** React + Tailwind CSS v4, móvil-primero, PWA. **Idioma de UI:** español.

---

## 0. Marca

El sistema es de **Ayax Sistemas de Seguridad**. El color y la tipografía no son una
elección de diseño: salen del sitio de la empresa (`ayaxseguridad.com`) y son lo que la
gente ya asocia con Ayax.

### Logo

Archivo: `logo-ayax.svg` (96 × 36, `viewBox="0 0 96 36"`). La letra va en el naranja
de marca; el bajotítulo SISTEMAS DE SEGURIDAD viene incluido en el propio SVG.

| Fondo | Cómo va el logo |
|---|---|
| Oscuro (`--color-bg` en oscuro, o el carbón `#2D2D3A`) | Tal cual, en naranja |
| Claro | Tal cual. Si compite con un botón primario cerca, `filter: grayscale(1) brightness(.35)` |
| Una sola tinta | Negro o blanco plenos. Nunca recolorear a otro tono |

Alto mínimo **24 px**. Aire libre alrededor: la altura de la A. No estirarlo, no
rotarlo, no ponerle sombra, no encerrarlo en una caja.

<details>
<summary>El SVG, para pegarlo donde haga falta</summary>

```svg
<svg width="96" height="36" viewBox="0 0 96 36" fill="none" xmlns="http://www.w3.org/2000/svg">
<g clip-path="url(#clip0_1205_7272)">
<path d="M30.4945 27.6383L32.5083 18.439L27.3516 0H35.6497L37.9859 10.8861H38.2678L43.9898 2.10052C44.8428 0.790036 46.3029 0 47.87 0H53.858L40.8065 18.439L38.8331 27.6383H30.4945Z" fill="#FF6700"/>
<path d="M95.9978 0H89.0874C87.6765 0 86.3421 0.642986 85.4646 1.74587L80.811 7.59185H80.4481L77.8704 0H68.7266L74.4471 13.4566L70.3154 18.0901L71.151 27.6455L77.9514 19.885H78.3533L81.0929 27.6383H90.1977L84.4772 13.8184L95.9978 0Z" fill="#FF6700"/>
<path d="M3.90766 33.9486C3.78767 33.7612 3.61563 33.6069 3.38721 33.4873C3.1588 33.3691 2.79015 33.2566 2.28127 33.1485C1.79697 33.0505 1.49194 32.9596 1.35604 32.8746C1.22304 32.791 1.15365 32.6915 1.15365 32.5689C1.15365 32.4464 1.23027 32.3412 1.37773 32.259C1.52519 32.1768 1.73915 32.1336 2.01093 32.1336C2.28272 32.1336 2.49379 32.1811 2.64269 32.2763C2.78726 32.3729 2.88557 32.5372 2.93038 32.7809L3.94525 32.7405C3.9279 32.3066 3.75152 31.9721 3.41902 31.7385C3.08651 31.5064 2.62824 31.3896 2.03406 31.3896C1.64229 31.3896 1.31123 31.4372 1.04089 31.5381C0.774881 31.6376 0.563813 31.7861 0.410571 31.9779C0.260221 32.1739 0.185046 32.3931 0.185046 32.6367C0.185046 32.8457 0.242873 33.0375 0.361419 33.2177C0.48141 33.4022 0.638988 33.5478 0.842828 33.6588C1.04089 33.7699 1.35749 33.8722 1.79119 33.9674C2.27549 34.074 2.57764 34.1505 2.70197 34.1951C2.82774 34.2427 2.92026 34.3018 2.98243 34.3725C3.04459 34.4431 3.07495 34.5282 3.07495 34.6291C3.07495 34.8021 2.98821 34.9448 2.81039 35.063C2.63691 35.1798 2.39259 35.2375 2.08611 35.2375C1.46736 35.2375 1.1016 34.9535 0.990287 34.3811L0 34.4691C0.138785 35.4883 0.82548 35.9958 2.05719 35.9958C2.75256 35.9958 3.26578 35.866 3.59539 35.6022C3.92501 35.3384 4.08837 35.0126 4.08837 34.6248C4.08837 34.3566 4.03054 34.1317 3.90766 33.9443V33.9486Z" fill="white"/>
<path d="M5.92893 31.4658H4.91406V35.922H5.92893V31.4658Z" fill="white"/>
<path d="M10.5483 33.9476C10.4283 33.7602 10.2563 33.606 10.0264 33.4863C9.79942 33.3681 9.43078 33.2556 8.9219 33.1475C8.44194 33.0495 8.13112 32.9587 7.99667 32.8736C7.86367 32.79 7.79572 32.6905 7.79572 32.568C7.79572 32.4454 7.86945 32.3402 8.01835 32.258C8.16437 32.1744 8.37833 32.1326 8.65011 32.1326C8.9219 32.1326 9.13441 32.1802 9.28187 32.2753C9.43078 32.3719 9.52619 32.5362 9.57101 32.7799L10.5873 32.7395C10.5671 32.3056 10.3921 31.9711 10.0596 31.7376C9.72859 31.5054 9.26742 31.3887 8.67469 31.3887C8.28291 31.3887 7.95185 31.4362 7.68296 31.5372C7.41551 31.6366 7.20444 31.7851 7.0512 31.9769C6.90229 32.1729 6.82567 32.3921 6.82567 32.6357C6.82567 32.8448 6.88205 33.0365 7.00204 33.2167C7.12059 33.4012 7.27961 33.5469 7.48345 33.6579C7.68296 33.7689 7.99956 33.8712 8.43182 33.9664C8.91467 34.0731 9.21682 34.1495 9.34404 34.1942C9.46836 34.2417 9.56233 34.3009 9.62305 34.3715C9.68377 34.4421 9.71557 34.5272 9.71557 34.6281C9.71557 34.8011 9.62883 34.9438 9.44957 35.0621C9.27753 35.1788 9.03322 35.2365 8.72673 35.2365C8.10798 35.2365 7.74367 34.9525 7.63091 34.3801L6.64062 34.4681C6.77941 35.4873 7.46321 35.9948 8.69782 35.9948C9.39463 35.9948 9.9064 35.8651 10.2375 35.6012C10.5613 35.3374 10.7275 35.0116 10.7275 34.6238C10.7275 34.3556 10.6697 34.1307 10.5483 33.9433V33.9476Z" fill="white"/>
<path d="M11.2188 31.4658V32.2213H12.7107V35.922H13.7241V32.2213H15.2146V31.4658H11.2188Z" fill="white"/>
<path d="M16.8855 35.1709V33.957H19.414V33.2074H16.8855V32.2213H19.6077V31.4658H15.875V35.922H19.6974V35.1709H16.8855Z" fill="white"/>
<path d="M23.8771 31.4658L22.9721 34.5077L22.0599 31.4658H20.5391V35.922H21.4889V32.413L22.4792 35.922H23.4579L24.4568 32.413V35.922H25.3994V31.4658H23.8771Z" fill="white"/>
<path d="M28.9315 31.4658H27.8559L25.8984 35.922H26.9755L27.3904 34.9085H29.397L29.835 35.922H30.9395L28.93 31.4658H28.9315ZM27.6997 34.1603L28.3807 32.5053L29.0702 34.1603H27.6983H27.6997Z" fill="white"/>
<path d="M35.1293 33.9476C35.0079 33.7602 34.8329 33.606 34.606 33.4863C34.3804 33.3681 34.0103 33.2556 33.5015 33.1475C33.0201 33.0495 32.7107 32.9587 32.5777 32.8736C32.4418 32.79 32.3753 32.6905 32.3753 32.568C32.3753 32.4454 32.449 32.3402 32.5979 32.258C32.7439 32.1744 32.9564 32.1326 33.2297 32.1326C33.5029 32.1326 33.714 32.1802 33.86 32.2753C34.0103 32.3719 34.1058 32.5362 34.1491 32.7799L35.1669 32.7395C35.1466 32.3056 34.9717 31.9711 34.6392 31.7376C34.3082 31.5054 33.847 31.3887 33.2543 31.3887C32.8596 31.3887 32.53 31.4362 32.2611 31.5372C31.9951 31.6366 31.7855 31.7851 31.6322 31.9769C31.4804 32.1729 31.4052 32.3921 31.4052 32.6357C31.4052 32.8448 31.4616 33.0365 31.5816 33.2167C31.7016 33.4012 31.8592 33.5469 32.0601 33.6579C32.2611 33.7689 32.5777 33.8712 33.0114 33.9664C33.4942 34.0731 33.7964 34.1495 33.9222 34.1942C34.0479 34.2417 34.1419 34.3009 34.2012 34.3715C34.2677 34.4421 34.2937 34.5272 34.2937 34.6281C34.2937 34.8011 34.207 34.9438 34.0291 35.0621C33.8542 35.1788 33.6128 35.2365 33.3063 35.2365C32.6861 35.2365 32.3204 34.9525 32.2119 34.3801L31.2188 34.4681C31.3575 35.4873 32.0442 35.9948 33.2774 35.9948C33.9742 35.9948 34.486 35.8651 34.817 35.6012C35.1438 35.3374 35.3071 35.0116 35.3071 34.6238C35.3071 34.3556 35.2478 34.1307 35.1293 33.9433V33.9476Z" fill="white"/>
<path d="M42.1607 32.6682C42.0465 32.3784 41.8904 32.1434 41.688 31.9646C41.4856 31.7844 41.2688 31.6561 41.0302 31.5812C40.7888 31.5047 40.4346 31.4658 39.9676 31.4658H38.1172V35.922H40.0226C40.436 35.922 40.7686 35.8788 41.0317 35.7966C41.2904 35.7101 41.5131 35.5876 41.6967 35.4218C41.8788 35.2531 42.0335 35.0268 42.155 34.7442C42.2749 34.4587 42.3342 34.1228 42.3342 33.7379C42.3342 33.3112 42.2793 32.9536 42.1622 32.6682H42.1607ZM41.1907 34.4746C41.13 34.6721 41.0519 34.8119 40.9579 34.9013C40.8654 34.9922 40.744 35.057 40.5994 35.1046C40.4519 35.1479 40.2149 35.1709 39.8896 35.1709H39.1277V32.2213H39.5903C39.9966 32.2213 40.2712 32.2342 40.4129 32.2587C40.6009 32.2919 40.7628 32.3669 40.8958 32.475C41.0288 32.5846 41.1256 32.7345 41.1878 32.9234C41.25 33.1122 41.2847 33.3746 41.2847 33.7047C41.2847 34.0349 41.2529 34.2814 41.1907 34.4746Z" fill="white"/>
<path d="M44.2073 35.1709V33.957H46.7358V33.2074H44.2073V32.2213H46.9266V31.4658H43.1953V35.922H47.0177V35.1709H44.2073Z" fill="white"/>
<path d="M53.4794 33.9476C53.3609 33.7602 53.1859 33.606 52.9575 33.4863C52.7306 33.3681 52.3634 33.2556 51.853 33.1475C51.3702 33.0495 51.0622 32.9587 50.9292 32.8736C50.7962 32.79 50.7254 32.6905 50.7254 32.568C50.7254 32.4454 50.802 32.3402 50.9509 32.258C51.0984 32.1744 51.3095 32.1326 51.5827 32.1326C51.8559 32.1326 52.0684 32.1802 52.213 32.2753C52.3605 32.3719 52.4588 32.5362 52.5007 32.7799L53.517 32.7395C53.4997 32.3056 53.3247 31.9711 52.9893 31.7376C52.6597 31.5054 52.1971 31.3887 51.6058 31.3887C51.2126 31.3887 50.8815 31.4362 50.6141 31.5372C50.3452 31.6366 50.137 31.7851 49.9838 31.9769C49.8349 32.1729 49.7583 32.3921 49.7583 32.6357C49.7583 32.8448 49.8146 33.0365 49.9332 33.2167C50.0517 33.4012 50.2122 33.5469 50.4131 33.6579C50.6141 33.7689 50.9307 33.8712 51.3615 33.9664C51.8458 34.0731 52.148 34.1495 52.2737 34.1942C52.4024 34.2417 52.492 34.3009 52.5556 34.3715C52.6149 34.4421 52.6467 34.5272 52.6467 34.6281C52.6467 34.8011 52.5571 34.9438 52.3807 35.0621C52.2058 35.1788 51.9672 35.2365 51.6593 35.2365C51.0406 35.2365 50.6719 34.9525 50.5635 34.3801L49.5703 34.4681C49.7091 35.4873 50.3958 35.9948 51.6318 35.9948C52.3243 35.9948 52.839 35.8651 53.1672 35.6012C53.4953 35.3374 53.6601 35.0116 53.6601 34.6238C53.6601 34.3556 53.6009 34.1307 53.4794 33.9433V33.9476Z" fill="white"/>
<path d="M55.4431 35.1709V33.957H57.9687V33.2074H55.4431V32.2213H58.1639V31.4658H54.4297V35.922H58.2535V35.1709H55.4431Z" fill="white"/>
<path d="M61.4593 33.5315V34.2826H62.6231V34.8477C62.454 34.9659 62.2646 35.0582 62.0535 35.1274C61.8367 35.1966 61.6314 35.2298 61.4333 35.2298C61.0112 35.2298 60.6743 35.1087 60.4271 34.8665C60.1351 34.5868 59.992 34.1773 59.992 33.6439C59.992 33.1422 60.1264 32.7688 60.3924 32.5252C60.6584 32.2815 61.0112 32.1575 61.4405 32.1575C61.721 32.1575 61.9624 32.2195 62.1648 32.3392C62.3643 32.4617 62.5031 32.6362 62.5754 32.8654L63.5816 32.6996C63.4775 32.2686 63.2433 31.9427 62.8862 31.7207C62.5248 31.5001 62.0434 31.3877 61.442 31.3877C60.9461 31.3877 60.5153 31.4742 60.1553 31.6443C59.7983 31.8188 59.5062 32.0783 59.2836 32.4286C59.0566 32.776 58.9453 33.1956 58.9453 33.6872C58.9453 34.1788 59.0566 34.5796 59.2778 34.9328C59.5004 35.2889 59.8011 35.5541 60.1799 35.7315C60.5601 35.9073 60.9982 35.9967 61.4955 35.9967C61.9003 35.9967 62.3051 35.9275 62.7098 35.792C63.1146 35.6579 63.4269 35.4936 63.6466 35.3047V33.5286H61.4593V33.5315Z" fill="white"/>
<path d="M67.4925 31.4653V33.9306C67.4925 34.3746 67.4651 34.6629 67.4101 34.7985C67.3566 34.934 67.254 35.0407 67.108 35.1142C66.9576 35.192 66.7668 35.2295 66.5326 35.2295C66.2579 35.2295 66.0367 35.1776 65.8705 35.068C65.6985 34.9599 65.5915 34.8071 65.5481 34.611C65.5221 34.4971 65.512 34.2549 65.512 33.8772V31.4639H64.5V33.8397C64.5 34.5058 64.5636 34.9657 64.6966 35.2137C64.8267 35.4616 65.0436 35.6548 65.337 35.7903C65.6305 35.9273 66.0396 35.9965 66.563 35.9965C67.0863 35.9965 67.4752 35.9129 67.7817 35.7485C68.0925 35.5842 68.2891 35.3679 68.3787 35.1012C68.464 34.8345 68.5089 34.402 68.5089 33.8037V31.4639H67.4925V31.4653Z" fill="white"/>
<path d="M73.3686 35.0537C73.1214 34.7033 72.9306 34.4626 72.7874 34.3256C72.6458 34.1916 72.465 34.069 72.2496 33.9537C72.6718 33.9003 72.9985 33.7663 73.2313 33.5543C73.4597 33.341 73.5739 33.057 73.5739 32.7124C73.5739 32.4356 73.5001 32.202 73.3484 32.0017C73.198 31.8056 73.0057 31.6657 72.7715 31.5865C72.5388 31.5072 72.1456 31.4668 71.5991 31.4668H69.4609V35.923H70.4758V34.0618H70.6869C70.9225 34.0618 71.0902 34.0777 71.1957 34.1108C71.3013 34.144 71.4025 34.2074 71.4964 34.2954C71.5933 34.3819 71.7711 34.601 72.0386 34.9513L72.773 35.9216H73.9816L73.3715 35.0522L73.3686 35.0537ZM71.2261 33.3511H70.4729V32.2208H71.2666C71.7234 32.2208 71.9995 32.2309 72.0921 32.2525C72.2265 32.2842 72.332 32.3448 72.4087 32.4298C72.4882 32.5178 72.5272 32.6302 72.5272 32.773C72.5272 32.9157 72.4882 33.0382 72.4087 33.129C72.3306 33.2184 72.2294 33.2761 72.1051 33.3049C71.9793 33.3352 71.6858 33.3496 71.2247 33.3496L71.2261 33.3511Z" fill="white"/>
<path d="M75.5056 31.4658H74.4922V35.922H75.5056V31.4658Z" fill="white"/>
<path d="M80.5216 32.6682C80.4059 32.3784 80.2483 32.1434 80.0474 31.9646C79.8464 31.7844 79.6281 31.6561 79.3896 31.5812C79.1482 31.5047 78.7954 31.4658 78.327 31.4658H76.4766V35.922H78.3834C78.7925 35.922 79.1294 35.8788 79.391 35.7966C79.6513 35.7101 79.871 35.5876 80.0546 35.4218C80.2382 35.2531 80.3958 35.0268 80.5143 34.7442C80.6329 34.4587 80.6936 34.1228 80.6936 33.7379C80.6936 33.3112 80.6358 32.9536 80.523 32.6682H80.5216ZM79.5501 34.4746C79.4879 34.6721 79.4098 34.8119 79.3173 34.9013C79.2233 34.9922 79.1019 35.057 78.9559 35.1046C78.8113 35.1479 78.5728 35.1709 78.249 35.1709H77.4842V32.2213H77.9483C78.3545 32.2213 78.6292 32.2342 78.768 32.2587C78.9588 32.2919 79.1221 32.3669 79.2523 32.475C79.3867 32.5846 79.485 32.7345 79.5457 32.9234C79.6079 33.1122 79.6397 33.3746 79.6397 33.7047C79.6397 34.0349 79.6122 34.2814 79.5501 34.4746Z" fill="white"/>
<path d="M83.8284 31.4658H82.7543L80.7969 35.922H81.8768L82.2903 34.9085H84.2968L84.7363 35.922H85.8365L83.827 31.4658H83.8284ZM82.5982 34.1603L83.2805 32.5053L83.9716 34.1603H82.5967H82.5982Z" fill="white"/>
<path d="M90.42 32.6682C90.3029 32.3784 90.1468 32.1434 89.9458 31.9646C89.7434 31.7844 89.5222 31.6561 89.2866 31.5812C89.0481 31.5047 88.691 31.4658 88.2255 31.4658H86.375V35.922H88.2804C88.6924 35.922 89.0264 35.8788 89.288 35.7966C89.5497 35.7101 89.7694 35.5876 89.9545 35.4218C90.1381 35.2531 90.2928 35.0268 90.4128 34.7442C90.5328 34.4587 90.5906 34.1228 90.5906 33.7379C90.5906 33.3112 90.5342 32.9536 90.4214 32.6682H90.42ZM89.4471 34.4746C89.3863 34.6721 89.3097 34.8119 89.2129 34.9013C89.1218 34.9922 89.0018 35.057 88.8543 35.1046C88.7098 35.1479 88.4727 35.1709 88.1474 35.1709H87.3826V32.2213H87.8467C88.2529 32.2213 88.5247 32.2342 88.6707 32.2587C88.8601 32.2919 89.0191 32.3669 89.1536 32.475C89.2866 32.5846 89.3806 32.7345 89.4442 32.9234C89.5063 33.1122 89.5396 33.3746 89.5396 33.7047C89.5396 34.0349 89.5078 34.2814 89.4471 34.4746Z" fill="white"/>
<path d="M67.0762 0H58.4585C56.7252 0 55.1378 0.965921 54.3441 2.50274L41.375 27.6383H46.8035C48.5614 27.6383 50.1676 26.645 50.9483 25.0736L52.0513 22.8577L54.8024 17.0723L54.9253 16.8157L56.0211 14.5075L59.8247 6.8292H60.1471L60.8323 17.0723H59.5876C57.8008 17.0723 56.1729 18.0988 55.4082 19.7091L53.9104 22.8577H61.0738L61.4771 27.6383H69.4934L67.0762 0Z" fill="#FF6700"/>
<path d="M25.7012 0H17.0835C15.3502 0 13.7628 0.965921 12.9691 2.50274L0 27.6383H5.42851C7.18645 27.6383 8.79259 26.645 9.57326 25.0736L10.6763 22.8577L13.4274 17.0723L13.5503 16.8157L14.6461 14.5075L18.4497 6.8292H18.7721L19.4573 17.0723H18.2126C16.4258 17.0723 14.7979 18.0988 14.0332 19.7091L12.5354 22.8577H19.6988L20.1021 27.6383H28.1184L25.7012 0Z" fill="#FF6700"/>
</g>
<defs>
<clipPath id="clip0_1205_7272">
<rect width="96" height="36" fill="white"/>
</clipPath>
</defs>
</svg>
```

</details>

### El naranja, y por qué no es el del sitio

El naranja de marca es **`#FF6700`**. Sobre blanco da **2,9:1** de contraste — por debajo
del mínimo AA de 4,5:1, así que no se puede usar para un botón con texto encima ni para
texto. La escala de este sistema mantiene su tono exacto (24°) y le baja saturación y luz:
el primario **`#D36922`** se lee como el mismo naranja pero funciona en pantalla.

`#FF6700` queda reservado **solo para el logo**, que es donde corresponde: ahí es una
imagen de marca, no un elemento de interfaz.

---

## 1. Principios

Ayax es una empresa de sistemas de seguridad. Este design system cubre sus herramientas
internas: el CRM de atención al cliente, el panel de presentismo y la encuesta de clima.

Dos formas muy distintas de usarlas, y el diseño tiene que servir a las dos:

- **Quien lo mira todo el día** — las áreas (AT Cliente, Comercial, Monitoreo, Técnica,
  RR.HH., Administración) trabajan sobre una tabla durante toda la jornada, en escritorio.
  Necesitan densidad, poder distinguir un estado de lejos y que nada canse la vista.
- **Quien lo abre una vez** — el personal que contesta la encuesta de clima, o consulta algo
  puntual, entra desde el celular y no vuelve. Necesita que se entienda sin explicación,
  con tamaños cómodos y una sola cosa por pantalla.

Personalidad: **profesional, confiable y enérgico**. Preciso, mucho aire, tipografía
impecable, color contenido.

Reglas rectoras (en caso de duda, prioriza en este orden):
1. **Solidez y confianza** por encima de todo.
2. **Simplicidad y legibilidad** — una idea principal por pantalla.
3. **Velocidad** — interacciones rápidas, sin fricción.

Mantras de diseño:
- El naranja se gana su lugar: **acciones primarias, estado activo y foco**. Nunca como relleno decorativo.
- **Una sola acción primaria por vista.**
- Separa con **bordes finos de 1px + sombras muy sutiles**, no con sombras marcadas.
- Fondo gris claro + tarjetas blancas = la base de toda composición.
- Cifras siempre en **mono tabular**, alineadas a la derecha.

---

## 2. Color

Usa SIEMPRE los **tokens semánticos**. Las escalas crudas existen solo para construir los semánticos o para gráficos.

### Tokens semánticos — modo claro

| Token | Valor | Uso |
|---|---|---|
| `--color-primary` | `#D36922` | Acción primaria, activo, foco |
| `--color-primary-hover` | `#B1571B` | Hover de primario |
| `--color-primary-active` | `#8C4617` | Pressed de primario |
| `--color-primary-subtle` | `#FEF6F1` | Fondo suave (avatar, chip activo) |
| `--color-on-primary` | `#FFFFFF` | Texto/icono sobre primario |
| `--color-bg` | `#F7F8F9` | Lienzo de la app |
| `--color-surface` | `#FFFFFF` | Tarjetas, superficies |
| `--color-surface-2` | `#F1F2F4` | Superficie hundida, inputs, hover |
| `--color-border` | `#E8EAED` | Borde 1px por defecto |
| `--color-border-strong` | `#D8DBDF` | Borde de inputs/controles |
| `--color-text` | `#1A1D21` | Texto principal |
| `--color-text-muted` | `#656C75` | Texto secundario |
| `--color-text-subtle` | `#868D96` | Texto terciario, placeholders |
| `--color-focus` | `#D36922` | Anillo de foco |

### Semánticos de estado (par fg / bg / text)

| Estado | `*` (fg) | `*-bg` | `*-text` |
|---|---|---|---|
| success | `#15803D` | `#ECFDF3` | `#166534` |
| warning | `#B45309` | `#FFFBEB` | `#92400E` |
| error | `#DC2626` | `#FEF2F2` | `#991B1B` |
| info | `#2563EB` | `#EFF6FF` | `#1E40AF` |

### Modo oscuro (redefine solo los semánticos)

| Token | Valor |
|---|---|
| `--color-primary` | `#DE7935` |
| `--color-primary-hover` | `#E2915A` |
| `--color-primary-active` | `#E8B491` |
| `--color-primary-subtle` | `rgba(222,121,53,.16)` |
| `--color-on-primary` | `#43240F` |
| `--color-bg` | `#0E0F11` |
| `--color-surface` | `#16181B` |
| `--color-surface-2` | `#1C1F23` |
| `--color-border` | `#2A2E33` |
| `--color-border-strong` | `#3A3F45` |
| `--color-text` | `#ECEDEE` |
| `--color-text-muted` | `#9BA1A8` |
| `--color-text-subtle` | `#71777E` |
| success / warning / error / info (fg) | `#4ADE80` / `#FBBF24` / `#F87171` / `#60A5FA` |

Activación del modo oscuro: atributo `data-theme="dark"` en la raíz (`<html>` o contenedor).

### Escalas crudas

**Naranja Ayax:** 50 `#FEF6F1` · 100 `#F7EBE3` · 200 `#F0D4C1` · 300 `#E8B491` · 400 `#E2915A` · 500 `#DE7935` · **600 `#D36922` (primario)** · 700 `#B1571B` · 800 `#8C4617` · 900 `#6B3714` · 950 `#43240F`

**Neutros (fríos):** 0 `#FFFFFF` · 50 `#F7F8F9` · 100 `#F1F2F4` · 200 `#E8EAED` · 300 `#D8DBDF` · 400 `#B0B5BC` · 500 `#868D96` · 600 `#656C75` · 700 `#4A5159` · 800 `#2E3338` · 900 `#1A1D21` · 950 `#0E0F11`

---

## 3. Tipografía

- **Sans (todo el texto):** `Inter` — es la del sitio de Ayax, servida desde
  `ayaxseguridad.com/tipografia/Inter-VariableFont_slnt,wght.ttf`. Fallback
  `system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`.
- **Mono tabular (cifras, importes, datos en tablas):** `JetBrains Mono`, fallback `ui-monospace, "SF Mono", Menlo, monospace`. Usar `font-variant-numeric: tabular-nums` y alinear a la derecha.
- **Pesos:** 400 cuerpo · 500 etiquetas/énfasis · 600 títulos. **Evitar 700.**
- **Tracking:** `-0.011em` en títulos y texto general.

### Escala (equilibrada)

| Token | px / rem | Peso típico | Uso |
|---|---|---|---|
| `--text-4xl` | 36 / 2.25rem | 600 | Título de página |
| `--text-3xl` | 30 / 1.875rem | 600 | Encabezado de sección grande |
| `--text-2xl` | 24 / 1.5rem | 600 | Encabezado |
| `--text-xl` | 20 / 1.25rem | 600 | Título de tarjeta |
| `--text-lg` | 18 / 1.125rem | 500 | Subtítulo / etiqueta grande |
| `--text-base` | 16 / 1rem | 400 | Cuerpo (base móvil) |
| `--text-sm` | 14 / 0.875rem | 400 | Texto secundario |
| `--text-xs` | 12 / 0.75rem | 500 | Etiqueta menor (mayúsculas, tracking .06em) |

`line-height`: 1.2 títulos · 1.5 cuerpo. Nunca texto < 14px en móvil para contenido legible (12px solo etiquetas).

---

## 4. Espaciado, layout y forma

- **Escala base 8px:** 4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 48 · 64. Todo padding/margin/gap es múltiplo de la escala.
- **Layout con flex/grid + `gap`**, no márgenes sueltos.
- **Ancho máximo de contenido:** 1200px, centrado en escritorio.
- **Breakpoints (Tailwind):** sm 640 · md 768 · lg 1024 · xl 1280.
- **Radios:** `sm 4px` · `md 6px` (general) · `lg 8px` · `xl 10px` (tarjetas/modales) · `2xl 16px` · `full 9999px` (pills, avatares).
- **Sombras (muy sutiles):**
  - `--shadow-xs`: `0 1px 2px rgba(16,24,32,.04)`
  - `--shadow-sm`: `0 1px 2px rgba(16,24,32,.06), 0 1px 3px rgba(16,24,32,.05)`
  - `--shadow-md`: `0 2px 4px rgba(16,24,32,.05), 0 4px 12px rgba(16,24,32,.06)`
  - `--shadow-lg`: `0 8px 24px rgba(16,24,32,.10)`
- **Bordes:** 1px `--color-border` como recurso principal de separación.

### Navegación

- **Móvil:** tab bar inferior fija de **5 ítems** (Inicio · Contactos · Ventas · Informes · Más). Si hay más destinos, el 5º ("Más") abre una hoja con el resto. Altura ~64px, cada ítem ≥56px de alto táctil.
- **Escritorio:** barra lateral o superior; contenido centrado a 1200px.

---

## 5. Densidad e interacción

- **Densidad adaptativa:** cómoda en móvil, compacta en tablas de escritorio.
- **Altura de controles:** **48px** por defecto (móvil), 44px compacto (escritorio/tablas).
- **Área táctil mínima:** **44×44px**.
- **Microinteracciones:** rápidas y sutiles — `transition` 150ms con `cubic-bezier(0.2,0,0,1)`. Sin rebotes ni animaciones largas.

### Estados (documenta TODOS en cada componente interactivo)

| Estado | Tratamiento |
|---|---|
| Reposo | Estilo base |
| Hover | Oscurece primario (`-hover`) / fondo `surface-2` en secundarios |
| Focus | Anillo naranja de 2px con separación: `box-shadow: 0 0 0 2px var(--color-surface), 0 0 0 4px var(--color-focus)` |
| Activo/pressed | `-active` + `translateY(1px)` opcional |
| Deshabilitado | Fondo `surface-2`, texto `subtle`, `cursor:not-allowed`, sin sombra |
| Error | Borde `--color-error` + halo `0 0 0 3px var(--color-error-bg)` + mensaje con icono |
| Cargando | Spinner (borde girando) o skeleton con `pulse`; deshabilita interacción |
| Seleccionado | Fondo `surface-2` o `primary-subtle`, marca textual/icono |
| Vacío | Icono en cuadro `surface-2`, título, una línea de ayuda y CTA primario |

---

## 6. Accesibilidad

- Contraste mínimo **WCAG AA** (4.5:1 texto normal, 3:1 texto grande).
- Foco **siempre visible** con el anillo naranja de 2px.
- Área táctil ≥44px. Etiquetas asociadas a inputs. Estados de error con texto + icono, no solo color.

---

## 7. Iconografía

- **Lucide** (https://lucide.dev), trazo **1.5px**, tamaños 16 / 20 / 24px, `stroke="currentColor"`.
- Interfaz **data-first**: casi sin imágenes. Avatares de **iniciales** sobre `primary-subtle`. Sin emoji.

---

## 8. Componentes (especificaciones)

Alturas: control 48px (móvil) / 44px (compacto). Radio general 6px.

### Botón
- **Primario:** `background:--color-primary; color:--color-on-primary; border:none; radius:6px; font-weight:600; font-size:15px; height:48px; padding:0 20px`. Hover `-hover`, activo `-active`, focus anillo, deshabilitado fondo `surface-2`+texto `subtle`+borde `border`, cargando con spinner 16px.
- **Secundario:** `background:--color-surface; border:1px solid --color-border-strong; color:--color-text; font-weight:500`. Hover fondo `surface-2`.
- **Fantasma (ghost):** transparente, `color:--color-text-muted`. Hover fondo `surface-2`.
- **Destructivo:** `background:--color-error; color:#fff; font-weight:600`. Hover `brightness(.9)`.
- **Icono:** cuadrado 48×48 (o 44), mismas variantes.

### Input / campo
`height:48px; padding:0 14px; border:1px solid --color-border-strong; radius:6px; background:--color-surface; font-size:15px`. Label 14px/500 encima. Focus borde `--color-primary` + anillo. Error borde `--color-error` + halo `error-bg` + mensaje 13px `error-text` con icono. Con icono: padding-left 40px, icono `subtle` a 14px. Deshabilitado fondo `surface-2`.

### Tarjeta
`background:--color-surface; border:1px solid --color-border; radius:10px; box-shadow:--shadow-xs`. Padding 20px. Cabecera con título 15px/600 y acción opcional en `--color-primary`.

### Badge / pill de estado
`radius:9999px; padding:5px 12px; font-size:13px; font-weight:500`. Punto de 7px del color `fg`. Pares: Ganado=success · Pendiente=warning · Perdido=error · Nuevo lead=info · En negociación=primary-subtle/primary · Borrador=neutral (surface-2 + borde).

### Avatar
Círculo 40px (`full`), `background:--color-primary-subtle; color:--color-primary; font-weight:600; font-size:14px`, iniciales. Variante neutra: `surface-2` + `text-muted`.

### Lista
Filas con `padding:14px 18px`, separadas por borde 1px. Avatar + (nombre 15px/500 · empresa 13px muted) + importe mono a la derecha. Fila seleccionada: fondo `surface-2`.

### Tab bar (móvil)
Contenedor `surface`, borde superior 1px, 5 ítems en flex. Ítem: icono 22px + label 11px. Activo `--color-primary`/600; inactivo `--color-text-subtle`/500. Cada ítem ≥56px alto.

### KPI / métrica
Tarjeta con etiqueta 13px muted + cifra mono 30px/500 tabular + delta en pill (success/error).

### Estados de carga y vacío
Skeleton: bloques `surface-2` con `@keyframes` pulse (opacity 1↔.45, 1.4s). Spinner: borde 3px `surface-2` con `border-top-color:--color-primary`, `@keyframes spin .7s linear infinite`. Vacío: icono Lucide en cuadro `surface-2` 48px + título 15px/600 + ayuda 13px muted + CTA primario.

---

## 9. Snippet de tokens (CSS)

```css
:root{
  --color-primary:#D36922;--color-primary-hover:#B1571B;--color-primary-active:#8C4617;
  --color-primary-subtle:#FEF6F1;--color-on-primary:#fff;
  --color-bg:#F7F8F9;--color-surface:#fff;--color-surface-2:#F1F2F4;
  --color-border:#E8EAED;--color-border-strong:#D8DBDF;
  --color-text:#1A1D21;--color-text-muted:#656C75;--color-text-subtle:#868D96;
  --color-focus:#D36922;
  --color-success:#15803D;--color-success-bg:#ECFDF3;--color-success-text:#166534;
  --color-warning:#B45309;--color-warning-bg:#FFFBEB;--color-warning-text:#92400E;
  --color-error:#DC2626;--color-error-bg:#FEF2F2;--color-error-text:#991B1B;
  --color-info:#2563EB;--color-info-bg:#EFF6FF;--color-info-text:#1E40AF;
  --shadow-xs:0 1px 2px rgba(16,24,32,.04);
  --shadow-sm:0 1px 2px rgba(16,24,32,.06),0 1px 3px rgba(16,24,32,.05);
  --shadow-md:0 2px 4px rgba(16,24,32,.05),0 4px 12px rgba(16,24,32,.06);
  --shadow-lg:0 8px 24px rgba(16,24,32,.10);
}
[data-theme="dark"]{
  --color-primary:#DE7935;--color-primary-hover:#E2915A;--color-primary-active:#E8B491;
  --color-primary-subtle:rgba(222,121,53,.16);--color-on-primary:#43240F;
  --color-bg:#0E0F11;--color-surface:#16181B;--color-surface-2:#1C1F23;
  --color-border:#2A2E33;--color-border-strong:#3A3F45;
  --color-text:#ECEDEE;--color-text-muted:#9BA1A8;--color-text-subtle:#71777E;
  --color-focus:#E2915A;
  --color-success:#4ADE80;--color-success-bg:rgba(34,197,94,.14);--color-success-text:#86EFAC;
  --color-warning:#FBBF24;--color-warning-bg:rgba(217,119,6,.16);--color-warning-text:#FCD34D;
  --color-error:#F87171;--color-error-bg:rgba(220,38,38,.16);--color-error-text:#FCA5A5;
  --color-info:#60A5FA;--color-info-bg:rgba(37,99,235,.18);--color-info-text:#93C5FD;
}
```

Fuentes: Inter se sirve desde el propio sitio, no desde un CDN externo —
`@font-face { font-family: "Inter"; src: url("/tipografia/Inter-VariableFont_slnt,wght.ttf") format("truetype"); font-weight: 100 900; }`
Para la mono tabular alcanza con la del sistema: `ui-monospace, "SF Mono", Menlo, monospace`.

---

## 10. Checklist al crear una pantalla

- [ ] Fondo `--color-bg`, contenido en tarjetas `--color-surface` con borde 1px.
- [ ] Una sola acción primaria (botón naranja).
- [ ] Cifras en mono tabular alineadas a la derecha.
- [ ] Controles de 48px, área táctil ≥44px.
- [ ] Foco naranja visible en todo elemento interactivo.
- [ ] Estados cubiertos: hover, focus, activo, deshabilitado, error, cargando, vacío, seleccionado.
- [ ] Contraste AA en modo claro y oscuro.
- [ ] Iconos Lucide 1.5px; sin emoji; avatares de iniciales.
- [ ] El logo, si aparece, con su aire libre y alto ≥24px. Naranja `#FF6700` solo ahí.
- [ ] Espaciado en múltiplos de 8px; radios 6/10px; sombras sutiles.
- [ ] En móvil, navegación en tab bar inferior de 5 ítems.
