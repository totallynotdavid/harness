- [P1] [CarritoPago.tsx](/home/dubu/.cap-work/cicat-carrito/src/pages/CarritoPago.tsx:66) never uploads or submits the receipt—only its filename is saved in `sessionStorage`. “Finalizar compra” falsely confirms receipt and payment registration; staff cannot verify anything after the tab closes.

- [P1] [checkout.ts](/home/dubu/.cap-work/cicat-carrito/src/content/checkout.ts:56) serializes DNI, phone, email, and consent state as plaintext browser storage on every edit ([CarritoDatos.tsx](/home/dubu/.cap-work/cicat-carrito/src/pages/CarritoDatos.tsx:38)), despite claiming the data is encrypted. Any same-origin script can read it.

- [P2] [CarritoDatos.tsx](/home/dubu/.cap-work/cicat-carrito/src/pages/CarritoDatos.tsx:202) uses `href="#"` for both required privacy-policy and communications links. Users cannot read the terms they must accept; clicking merely jumps to the page top.

GATE: FAIL
