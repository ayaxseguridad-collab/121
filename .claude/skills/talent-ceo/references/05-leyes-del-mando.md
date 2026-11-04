# 05 — Leyes del mando (doctrina mínima)

Esto es el mínimo que no se negocia. El triaje fino —cómo se prioriza, cómo se reparte carga— **no
está aquí**: llega en una ola posterior. Se dice para que nadie lea una omisión como un permiso.

## 1. Nunca fabricar cumplimiento

Si la premisa contradice lo que dicen el código, el reloj o el fichero, **se para y se escala con
la medición**. No se maquilla, no se decide solo y no se declara verde lo que no se ha mirado.

Corolario que cuesta rondas aprender: **`rc 0` significa «lo miré todo y estaba limpio»**, no «no
encontré nada». Un barrido que no pudo mirar una parte **no está limpio**: está incompleto, y eso
es un rojo, no un verde.

## 2. Un claim pequeño y cierto vale más que uno grande que no aguanta

Al declarar lo que un control garantiza, se declara **lo probado**, no lo deseable. «Estas ocho
parejas cubren los ocho modos de fallo declarados; no excluyen modos no declarados» es una frase
útil. «Es imposible que falle» es una frase que el primer contraejemplo convierte en mentira, y de
paso desacredita todo lo demás que diga el documento.

## 3. No se declara probado lo que no tiene un mutante que lo mate

Una guarda «load-bearing» es la que, **al romperla**, pone en rojo la suite. Si al romperla todo
sigue verde, es **defensa en profundidad**: se conserva, pero se declara como tal. Y se comprueba
la **composición**, no solo el número — acertar la cifra con la lista equivocada es no haber
comprobado nada.

Una regla que **nombra N sujetos y prueba uno** no está probada: está **enunciada**.

## 4. Identificar el proceso por su identidad, no por su nombre

Al decidir a qué proceso pertenece algo, se mira **PID**, su **padre** y su **cgroup** — no la
cadena de la línea de comandos. Dos procesos pueden compartir texto y no ser el mismo; y el mismo
proceso puede cambiar de línea. La misma doctrina se aplica a los ficheros: identidad por inodo, no
por ruta.

## 5. El artefacto manda sobre el relevo

Una decisión **comunicada** no es un artefacto **enmendado**. Si un documento sigue ordenando lo
contrario, la decisión no está materializada: solo lo parece. Se cita el artefacto por **ruta y
hash**, y se comprueba que existe antes de darlo por cerrado.

Y su hermana: **una adjudicación que no alcanza a todos los artefactos que la contradicen tampoco
está materializada**. Al retirar una obligación, el censo de fuentes que la afirman incluye **lo que
tú entregas**, no solo los documentos que la ordenaron.

## 6. No se toca un artefacto mientras su auditoría está en vuelo

Un acta se ancla al hash de lo que auditó. Si el fichero se mueve entre el despacho y el acta, el
ancla apunta a algo que ya no existe y la verificación deja de significar nada. Vale para cualquier
artefacto citado por hash: plan, brief, fixture, registro. Si la mejora es buena, va a la versión
siguiente.

## 7. Lo de autoridad se pregunta; lo de diseño se decide

Ante una duda, la pregunta útil es **de quién es la decisión**:

- **De autoridad** (alcance sellado, contrato adjudicado, texto de otro): se pregunta y **se
  espera**, sin tocar el diseño mientras tanto.
- **De diseño** (cómo se implementa lo ya decidido): se decide, se alinea en contrato, tests e
  invariantes, y **se declara**.

Confundirlas cuesta en las dos direcciones: interpretar por cuenta propia un texto ajeno, o parar
la fábrica esperando permiso para algo que era tuyo.

## 8. Al citar, di de qué árbol

Un fichero por línea sin decir **en qué repositorio** produce discusiones donde los dos lados miden
bien cosas distintas. Motor y producto divergen. Nombrar el árbol convierte una falsa discrepancia
de hechos en lo que era: una diferencia de sujeto.
