#!/bin/bash
set -e  # Прекращение выполнения при любой ошибке




####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 6: Установка Rancher\033[0m"
####################################################################################################################
# Устанававливаем Helm
echo -e "\033[32m  Устанававливаем Helm\033[0m"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 || {
  echo -e "\033[31m  Ошибка при загрузке скрипта установки Helm\033[0m"; exit 1;
}
chmod 700 get_helm.sh
./get_helm.sh || {
  echo -e "\033[31m  Ошибка при установке Helm\033[0m"; exit 1;
}


# Добавляем репозиторий Rancher
echo -e "\033[32m  Добавляем репозиторий Rancher\033[0m"
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest || {
  echo -e "\033[31m  Ошибка при добавлении репозитория Rancher\033[0m"; exit 1;
}


# Создаем пространство имен
echo -e "\033[32m  Создаем пространство имен\033[0m"
kubectl create namespace cattle-system || {
  echo -e "\033[31m  Ошибка при создании пространства имен cattle-system\033[0m"; exit 1;
}


# Развертываем Cert-Manager
echo -e "\033[32m  Развертываем Cert-Manager\033[0m"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml || {
  echo -e "\033[31m  Ошибка при применении CRDs Cert-Manager\033[0m"; exit 1;
}
helm repo add jetstack https://charts.jetstack.io || {
  echo -e "\033[31m  Ошибка при добавлении репозитория Jetstack\033[0m"; exit 1;
}
helm repo update || {
  echo -e "\033[31m  Ошибка при обновлении репозиториев Helm\033[0m"; exit 1;
}
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.2 || {
  echo -e "\033[31m  Ошибка при установке Cert-Manager\033[0m"; exit 1;
}
kubectl get pods --namespace cert-manager || {
  echo -e "\033[31m  Ошибка при получении подов Cert-Manager\033[0m"; exit 1;
}


# Устанавливаем Rancher
echo -e "\033[32m  Развертываем Rancher\033[0m"
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher.poe-gw.keenetic.pro \
  --set bootstrapPassword=MCMega20051983! || {
  echo -e "\033[31m  Ошибка при развертывании Rancher\033[0m"; exit 1;
}
kubectl -n cattle-system rollout status deploy/rancher || {
  echo -e "\033[31m  Ошибка при проверке статуса развертывания Rancher\033[0m"; exit 1;
}
kubectl -n cattle-system get deploy rancher || {
  echo -e "\033[31m  Ошибка при получении информации о развертывании Rancher\033[0m"; exit 1;
}


# Добавляем LoadBalancer для Rancher
echo -e "\033[32m  Добавляем LoadBalancer для Rancher\033[0m"
kubectl get svc -n cattle-system || {
  echo -e "\033[31m  Ошибка при получении сервисов в пространстве имен cattle-system\033[0m"; exit 1;
}
kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system || {
  echo -e "\033[31m  Ошибка при создании LoadBalancer для Rancher\033[0m"; exit 1;
}


# Ожидаем готовности LoadBalancer
while [[ $(kubectl get svc -n cattle-system 'jsonpath={..status.conditions[?(@.type=="Pending")].status}') = "True" ]]; do
  sleep 10
  echo -e "\033[32m  Ожидаем готовности LoadBalancer для Rancher\033[0m"
done


kubectl get svc -n cattle-system || {
  echo -e "\033[31m  Ошибка при получении информации о сервисах после ожидания\033[0m"; exit 1;
}


# Проверяем состояние узлов
echo -e "\033[32m  Состояние узлов:\033[0m"
kubectl get nodes
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mДоступ к Rancher по указанному IP и порту (пароль: MCMega20051983!)\033[0m"
echo -e "\033[32mRancher установлен и готов к работе!\033[0m"
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"



# Можно получить SSL сертификат
# https://github.com/JamesTurland/JimsGarage/blob/main/Kubernetes/Rancher-Deployment/readme.md
