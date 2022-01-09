$serviceName = "agileteam"
$environment = "dev"

terraform apply -input=false `
    -auto-approve `
    -var="service_name=${serviceName}" `
    -var-file=".\config\base.tfvars" `
    -var-file=".\config\${environment}.tfvars"