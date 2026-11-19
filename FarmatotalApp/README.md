# Farmatotal para iPhone

App nativa (SwiftUI, iOS 17+) para la tienda online de [farmatotal.com.py](https://www.farmatotal.com.py).

## Cómo abrirla

1. En una Mac con Xcode 15 o posterior, abrí `Farmatotal.xcodeproj`.
2. En *Signing & Capabilities*, elegí tu equipo (Team). Si no vas a publicarla como Farmatotal, cambiá el Bundle Identifier (`py.com.farmatotal.app`).
3. Elegí un iPhone o un simulador y tocá ▶︎. Los tests se corren con ⌘U.

El proyecto se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen). Si modificás `project.yml`, ejecutá `xcodegen generate`.

## Funciones del sitio y cómo están en la app

| En la web | En la app |
|---|---|
| Inicio con ofertas, “Super Rombo”, descuentos de 70% y 50%, canje de puntos | **Inicio** nativo: banners, categorías, carruseles de Ofertas, Más vendidos y Canjeá tus puntos |
| Menú de categorías y subcategorías (Medicamentos → Antihistamínico → Cetirizina…) | Pestaña **Categorías** con subcategorías en chips |
| Ordenar (popularidad, últimos, precio), filtro de precio | Menú de filtros: orden, “Solo ofertas” y rango de precio. Scroll infinito |
| Buscador, escaneo de código de barras, búsqueda por voz | Pestaña **Buscar**: texto, escáner (cámara + linterna + ingreso manual) y voz. El código escaneado se busca como SKU |
| Ficha: Precio normal / Precio web, % de descuento, SKU, stock, cantidad, descripción, categoría/etiqueta, relacionados | Ficha nativa con galería, compartir, favoritos y comparar |
| Mis Favoritos (wishlist) | Favoritos (se guardan en el teléfono) |
| Comparar productos | Comparador de hasta 4 productos lado a lado |
| Carrito | **Carrito** nativo. Es el mismo carrito del sitio, porque usa la misma sesión |
| Caja: sucursal, CI/RUC, validación de stock por sucursal, pago con Bancard | **Finalizar compra** abre la caja real del sitio dentro de la app, así que el pago y las validaciones son los mismos |
| Selector “Sucursal más cercana” (`?inventory=…`) | Botón de sucursal en Inicio y en Cuenta. Usa el selector del propio sitio, así que el stock queda igual que en la web |
| Página de Sucursales con mapa | **Sucursales** nativo: mapa, “más cercana” con GPS, llamar, cómo llegar y email |
| Mi cuenta (login, pedidos, direcciones), ¿Dónde está mi pedido?, Contacto | Pestaña **Cuenta**. Estas páginas se abren dentro de la app sin el encabezado del sitio |

## Cómo funciona

- **Datos:** se usa la API pública de WooCommerce (Store API, `/wp-json/wc/store/v1`): productos, categorías y carrito.
- **Cloudflare:** el sitio bloquea a los clientes que no son navegadores. Por eso todas las llamadas pasan por un `WKWebView` oculto (`WebBridge.swift`), que tiene las mismas cookies que Safari dentro de la app. Si Cloudflare pide confirmar que sos una persona, la app muestra esa verificación para que el usuario la complete. No se intenta saltarla.
- Las páginas que se abren dentro de la app (caja, cuenta, sucursal) comparten esa sesión, por lo que el carrito y el login son los mismos.

## Lo que no pude probar (leer antes de publicar)

Cloudflare bloqueó el sitio en vivo desde mi entorno, así que la estructura la saqué de copias públicas del sitio (Common Crawl, julio 2026). **La app no se compiló en Xcode**, porque no había una Mac disponible. Lo que sí se verificó:

- ✅ El modelo de datos, el formato de precios en ₲, la decodificación de HTML y las URLs de búsqueda compilan y pasan los tests (`FarmatotalTests`).
- ✅ Todos los archivos pasan el chequeo de sintaxis de Swift.
- ❓ **Sin probar:**
  - que la Store API esté habilitada en el sitio (es estándar en WooCommerce 10.9, la versión que usa el sitio);
  - el endpoint de sucursales (`asl_load_stores` del plugin Agile Store Locator); si falla, la app ofrece “Ver en la web”;
  - el formato de horarios de las sucursales;
  - el selector de sucursal: abre el popup del sitio y detecta el cambio leyendo el texto “Sucursal más cercana”.
- ⚠️ **Login con Google:** Google no permite iniciar sesión dentro de un `WKWebView`. Usuario/contraseña y Facebook deberían funcionar.
- ⚠️ El menú del sitio tiene un enlace **“Trabaja con Nosotros”** que no lleva a ninguna página (`href="#"`), así que no está en la app.
- ⚠️ Para publicarla en el App Store con la marca Farmatotal hace falta la autorización de la empresa (Defensores S.A.).
