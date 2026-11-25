@echo off
rem ==========================================================================
rem  LIMPIEZA TOTAL DEL PC (fase 3). Ejecutar SOLO despues de "make destroy".
rem  Uso, desde cmd en la carpeta del proyecto:  herramientas\limpiar-pc.bat
rem ==========================================================================
cd /d "%~dp0.."

rem --- Seguridad: no seguir si AWS todavia tiene cosas creadas -------------
if exist "infraestructura\terraform.tfstate" (
  findstr /c:"\"mode\": \"managed\"" "infraestructura\terraform.tfstate" >nul 2>&1
  if not errorlevel 1 (
    echo.
    echo  [ALTO] Terraform dice que TODAVIA hay recursos creados en AWS.
    echo  Primero borra AWS: abre la terminal de herramientas y escribe  make destroy
    echo  Cuando termine sin errores, vuelve a ejecutar este archivo.
    echo.
    pause
    exit /b 1
  )
)

docker info >nul 2>&1
if errorlevel 1 (
  echo.
  echo  [ERROR] Docker Desktop no esta abierto. Abrelo y vuelve a ejecutar esto.
  echo.
  pause
  exit /b 1
)

echo.
echo  Esto BORRA de tu PC todo lo de la fase 3:
echo    - contenedores, imagenes, volumenes y redes de Docker del proyecto
echo    - el contenedor de herramientas (aws_dev_environment)
echo    - .env, .env.cloud y los archivos de Terraform del proyecto
echo    - la llave labsuser.pem de Descargas
echo  NO borra tu codigo, los documentos ni salida-make-up.txt.
echo.
set /p RESP=  Escribe SI y Enter para continuar (otra cosa cancela):
if /i not "%RESP%"=="SI" (
  echo  Cancelado. No se borro nada.
  pause
  exit /b 0
)

echo.
echo  [1/6] Contenedores, volumenes y redes del proyecto...
docker compose --profile central down --rmi all -v --remove-orphans >nul 2>&1
for /f "tokens=*" %%v in ('docker volume ls -q --filter "name=d1-chain"') do docker volume rm %%v >nul 2>&1
for /f "tokens=*" %%n in ('docker network ls -q --filter "name=d1-chain"') do docker network rm %%n >nul 2>&1

echo  [2/6] Imagenes del proyecto (tiendas, sede central y las subidas a AWS)...
for /f "tokens=*" %%i in ('docker images --format "{{.Repository}}:{{.Tag}}" ^| findstr /c:"d1-chain" /c:"central-api" /c:"central-web" /c:"central-worker" /c:"central-db"') do docker rmi -f %%i >nul 2>&1

echo  [3/6] Cache de construccion de Docker...
docker builder prune -f >nul 2>&1

echo  [4/6] Archivos generados en el proyecto...
del /q ".env" ".env.cloud" "labsuser.pem" >nul 2>&1
if exist "infraestructura\.terraform" rmdir /s /q "infraestructura\.terraform"
del /q "infraestructura\terraform.tfstate" "infraestructura\terraform.tfstate.backup" "infraestructura\tfplan" "infraestructura\terraform.tfvars" >nul 2>&1

echo  [5/6] Llave SSH de Descargas...
del /q "%USERPROFILE%\Downloads\labsuser.pem" >nul 2>&1

echo  [6/6] Contenedor de herramientas aws_dev_environment (con las credenciales que tenia dentro)...
docker rm -f aws_dev_environment >nul 2>&1
docker rmi -f aws_dev_environment_image >nul 2>&1

echo.
echo  Listo. El PC quedo limpio de la fase 3.
echo  Falta solo: en el Learner Lab pulsa "End Lab".
echo.
pause
